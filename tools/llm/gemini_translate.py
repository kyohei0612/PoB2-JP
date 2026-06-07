#!/usr/bin/env python3
"""
gemini_translate.py — Phase 3.2 本番バッチ翻訳ランナー

PoB2-JP の全CSV辞書の未訳行(EN==JA)を Gemini でバッチ翻訳して埋める。
- 全CSV横断デデュープ（同一ENは1回翻訳→全箇所へ配布）
- 永続キャッシュ cache/llm-cache.json（再開可・無料枠の無駄打ち防止）
- キー×モデルローテーション＋429/失敗で次候補（youtube-pipeline 実証パターン）
- few-shot に既訳を使い house-style 踏襲。プレースホルダ {n}/#/^色 保持を厳命＆事後検証
- 検証ゲート: ph_count/{n}集合/色コード一致。NGは不採用（英語のまま・キャッシュにも入れない）
- --limit でこの実行の翻訳件数を上限（段階実行・無料枠配慮）。--apply でCSVへ反映(.llm-bak)

使い方:
  python gemini_translate.py --jp <ja-JP dir> --limit 300 [--apply]
      [--env .../youtube-pipeline/.env] [--batch 60] [--only statDescriptions.csv]
"""
import argparse, csv, glob, json, os, re, sys, time, hashlib

PH = re.compile(r"\{(\d+)\}")
def ph_set(s): return set(PH.findall(s))
def ph_count(s): return len(PH.findall(s)) + s.count("#")
def color_count(s): return len(re.findall(r"\^x[0-9A-Fa-f]{6}|\^[0-9]", s))
def sha(s): return hashlib.sha1(s.encode("utf-8")).hexdigest()

def load_env(path):
    keys = os.getenv("GEMINI_API_KEYS", "") or os.getenv("GEMINI_API_KEY", "")
    models = os.getenv("GEMINI_MODEL_CANDIDATES", "")
    if path and os.path.exists(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line: continue
            k, _, v = line.partition("="); k = k.strip(); v = v.strip().strip('"').strip("'")
            if k == "GEMINI_API_KEYS" and not keys: keys = v
            elif k == "GEMINI_API_KEY" and not keys: keys = v
            elif k == "GEMINI_MODEL_CANDIDATES" and not models: models = v
    keys = [k.strip() for k in keys.split(",") if k.strip()]
    models = [m.strip() for m in models.split(",") if m.strip()] or ["gemini-2.5-flash"]
    return keys, models

def read_rows(p):
    with open(p, encoding="utf-8-sig", newline="") as f: return list(csv.reader(f))

def valid(en, ja):
    if not ja or ja == en: return False
    if ph_count(ja) != ph_count(en): return False
    if ph_set(ja) != ph_set(en): return False
    if color_count(ja) != color_count(en): return False
    return True

_WORD = re.compile(r"[A-Za-z][A-Za-z'\-]+")

def build_glossary(translated_pairs, exiledesk_env):
    # 既訳から「短い用語行(1-3語・placeholder無)」を EN-term -> JA に。固有名詞の一貫性確保が主目的。
    from collections import Counter
    cand = {}
    for en, ja in translated_pairs:
        if ph_count(en) or "^" in en: continue
        words = _WORD.findall(en)
        if 1 <= len(words) <= 3 and en.strip() == " ".join(en.split()) and len(en) <= 40:
            cand.setdefault(en, Counter())[ja] += 1
    gloss = {en: c.most_common(1)[0][0] for en, c in cand.items()}
    # ExileDesk のユニーク名(固有名詞)を統合
    try:
        import os.path as op
        p = op.join(op.dirname(exiledesk_env), "src", "i18n", "unique-names-ja.json") if exiledesk_env else None
        if p and op.exists(p):
            d = json.load(open(p, encoding="utf-8-sig"))
            for k, v in d.items():
                if isinstance(v, str): gloss.setdefault(k, v)
    except Exception: pass
    return gloss  # key=EN term (原表記)

def relevant_gloss(batch, gloss, gl_lower):
    hits = {}
    blob = " " + " ".join(batch).lower() + " "
    for low, (en, ja) in gl_lower.items():
        # 全語一致（語境界）で出現する用語のみ注入
        if re.search(r"(?<![A-Za-z])" + re.escape(low) + r"(?![A-Za-z])", blob):
            hits[en] = ja
        if len(hits) >= 60: break
    return hits

def build_prompt(batch, examples, gloss_hits):
    ex = "\n".join(f"  EN: {e}\n  JA: {j}" for e, j in examples)
    gl = "\n".join(f"  {e} = {j}" for e, j in gloss_hits.items())
    gl_block = (f"\nGLOSSARY (use these EXACT Japanese terms for these words/names):\n{gl}\n" if gloss_hits else "")
    rules = (
        "You are a professional localizer for Path of Exile 2, translating UI/stat text to Japanese.\n"
        "Follow the established in-game Japanese wording in the examples and glossary (terminology and style).\n"
        "STRICT RULES:\n"
        "- Preserve every placeholder EXACTLY: {0},{1},... and # and color codes like ^xRRGGBB or ^7.\n"
        "- Keep the SAME NUMBER of placeholders as the source; never add/drop them; never turn # into a number.\n"
        "- Japanese may reorder placeholders, but every placeholder token must still appear.\n"
        "- For any word/name listed in the GLOSSARY, use that exact Japanese term.\n"
        '- Output JSON only: an array of {"id":<int>,"ja":<string>}. No prose.\n'
    )
    items = json.dumps([{"id": i, "en": en} for i, en in enumerate(batch)], ensure_ascii=False)
    return f"{rules}{gl_block}\nEXAMPLES (house style):\n{ex}\n\nTranslate to Japanese, return JSON array:\n{items}"

def call_gemini(genai, prompt, keys, models):
    last = "no-keys"
    for ki, key in enumerate(keys):
        try: client = genai.Client(api_key=key)
        except Exception as e: last = f"client:{e}"; continue
        for model in models:
            try:
                resp = client.models.generate_content(
                    model=model, contents=prompt,
                    config={"response_mime_type": "application/json", "temperature": 0.0})
                return json.loads(getattr(resp, "text", "") or ""), f"{model}/key{ki}"
            except Exception as e:
                last = f"{model}/key{ki}:{str(e)[:80]}"
                if "429" in last or "RESOURCE_EXHAUSTED" in last: time.sleep(2)
                continue
    return None, last

def load_openai_key(path):
    k = os.getenv("OPENAI_API_KEY", "")
    if not k and path and os.path.exists(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if line.startswith("OPENAI_API_KEY="):
                k = line.split("=", 1)[1].strip().strip('"').strip("'"); break
    return k

def call_openai(prompt, key, model):
    try:
        from openai import OpenAI
    except ImportError:
        return None, "openai SDK not installed"
    try:
        client = OpenAI(api_key=key)
        r = client.chat.completions.create(
            model=model, temperature=0,
            response_format={"type": "json_object"},
            messages=[{"role": "user", "content": prompt + '\nReturn a JSON object: {"translations":[{"id":<int>,"ja":<string>}]}.'}])
        txt = r.choices[0].message.content or ""
        obj = json.loads(txt)
        data = obj.get("translations") if isinstance(obj, dict) else obj
        return data, f"{model}"
    except Exception as e:
        return None, f"{model}:{str(e)[:80]}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jp", required=True)
    ap.add_argument("--env", default=r"C:\Users\kyohei\youtube-pipeline\.env")
    ap.add_argument("--limit", type=int, default=300)
    ap.add_argument("--batch", type=int, default=60)
    ap.add_argument("--only", default=None, help="特定CSVのみ（例 statDescriptions.csv）")
    ap.add_argument("--provider", default="gemini", choices=["gemini", "openai"])
    ap.add_argument("--model", default="gpt-4o-mini", help="openai時のモデル")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--cache", default=None)
    args = ap.parse_args()
    try: sys.stdout.reconfigure(encoding="utf-8")
    except Exception: pass

    genai = None; oai_key = None
    if args.provider == "gemini":
        keys, models = load_env(args.env)
        if not keys: print("NO GEMINI KEYS"); sys.exit(2)
        try: from google import genai
        except ImportError: print("google-genai SDK not installed"); sys.exit(2)
        print(f"provider=gemini keys={len(keys)} models={models}")
    else:
        oai_key = load_openai_key(args.env)
        if not oai_key: print("NO OPENAI KEY"); sys.exit(2)
        print(f"provider=openai model={args.model}")
    print(f"limit={args.limit} batch={args.batch}")

    cache_path = args.cache or os.path.join(os.path.dirname(__file__), "cache", "llm-cache.json")
    os.makedirs(os.path.dirname(cache_path), exist_ok=True)
    cache = json.load(open(cache_path, encoding="utf-8")) if os.path.exists(cache_path) else {}

    files = ([os.path.join(args.jp, args.only)] if args.only
             else sorted(glob.glob(os.path.join(args.jp, "*.csv"))))
    # 収集: EN -> [(file,rowidx)]、既訳 few-shot 候補
    occ = {}; examples = []
    file_rows = {}
    for p in files:
        rows = read_rows(p); file_rows[p] = rows
        for i, r in enumerate(rows):
            if len(r) < 2 or not r[0]: continue
            if r[0] == r[1]:
                occ.setdefault(r[0], []).append((p, i))
            elif len(examples) < 4000 and ph_count(r[0]) >= 0:
                examples.append((r[0], r[1]))
    uniq = [en for en in occ if en not in cache]
    print(f"未訳ユニーク={len(occ)}  キャッシュ既訳={sum(1 for en in occ if en in cache)}  今回対象(新規)={len(uniq)}")

    # few-shot 固定選抜（placeholder有り優先5 + 無し3）
    import random; random.seed(11)
    ph_ex = [e for e in examples if ph_count(e[0]) >= 1]
    pl_ex = [e for e in examples if ph_count(e[0]) == 0]
    fewshot = random.sample(ph_ex, min(5, len(ph_ex))) + random.sample(pl_ex, min(3, len(pl_ex)))

    # glossary: 既訳の短い用語行 + ExileDesk固有名詞 で確定訳を固定（一貫性）
    gloss = build_glossary(examples, args.env)
    gl_lower = {en.lower(): (en, ja) for en, ja in gloss.items()}
    print(f"glossary={len(gloss)} terms")

    todo = uniq[:args.limit]
    okc = ngc = 0
    for b in range(0, len(todo), args.batch):
        batch = todo[b:b + args.batch]
        gh = relevant_gloss(batch, gloss, gl_lower)
        prompt = build_prompt(batch, fewshot, gh)
        if args.provider == "gemini":
            data, status = call_gemini(genai, prompt, keys, models)
        else:
            data, status = call_openai(prompt, oai_key, args.model)
        if not data:
            print(f"  batch {b//args.batch}: FAIL {status}"); break
        by = {d["id"]: d.get("ja", "") for d in data if isinstance(d, dict)}
        for i, en in enumerate(batch):
            ja = by.get(i, "")
            if valid(en, ja): cache[en] = ja; okc += 1
            else: ngc += 1
        print(f"  batch {b//args.batch} [{status}]: OK累計{okc} NG累計{ngc}")
        json.dump(cache, open(cache_path, "w", encoding="utf-8"), ensure_ascii=False)  # 逐次保存=再開可
    print(f"\n翻訳: 採用{okc} 不採用{ngc} (採用率{100*okc/max(okc+ngc,1):.0f}%)  cache={len(cache)}")

    # 適用
    if args.apply:
        per = {}
        for p, rows in file_rows.items():
            changed = False; n = 0
            for r in rows:
                if len(r) >= 2 and r[0] and r[0] == r[1] and r[0] in cache:
                    if valid(r[0], cache[r[0]]):
                        r[1] = cache[r[0]]; changed = True; n += 1
            if changed:
                bak = p + ".llm-bak"
                if not os.path.exists(bak):
                    open(bak, "w", encoding="utf-8-sig", newline="").write(open(p, encoding="utf-8-sig").read())
                with open(p, "w", encoding="utf-8-sig", newline="") as f:
                    csv.writer(f, lineterminator="\n").writerows(rows)
                per[os.path.basename(p)] = n
        print("適用 per CSV:", dict(sorted(per.items(), key=lambda kv: -kv[1])))

if __name__ == "__main__":
    main()
