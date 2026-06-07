#!/usr/bin/env python3
"""
gemini_translate_poc.py — Phase 3.2 PoC: Gemini で PoB2-JP 未訳行を翻訳し品質/整合を実証する。

- キー/モデルは youtube-pipeline の .env から実行時に読む（POBJP リポに鍵を置かない / BYOK）。
- few-shot に既訳(同カテゴリ)を使い house-style を踏襲。プレースホルダ {n}/#/^色 は保持を厳命し、
  事後に ph_count 一致を機械検証。整合NGは不採用（英語のまま）。
- 既定は「提案のみ」（CSVは書き換えない）。--apply で EN==JA 行へマージ(.poc-bak)。

使い方:
  python gemini_translate_poc.py --csv <path/statDescriptions.csv> --n 30 \
      [--env C:\\Users\\kyohei\\youtube-pipeline\\.env] [--apply]
"""
import argparse, csv, json, os, re, sys, random

PH = re.compile(r"\{(\d+)\}")
def ph_set(s): return set(PH.findall(s))
def ph_count(s): return len(PH.findall(s)) + s.count("#")
def color_count(s): return len(re.findall(r"\^x[0-9A-Fa-f]{6}|\^[0-9]", s))

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

def read_rows(path):
    with open(path, encoding="utf-8-sig", newline="") as f:
        return list(csv.reader(f))

def build_prompt(batch, examples):
    ex = "\n".join(f'  EN: {e}\n  JA: {j}' for e, j in examples)
    rules = (
        "You are a professional localizer for the game Path of Exile 2, translating UI/stat text to Japanese.\n"
        "Follow the established in-game Japanese wording shown in the examples (terminology, style).\n"
        "STRICT RULES:\n"
        "- Preserve every placeholder EXACTLY and unchanged: {0},{1},... and # and color codes like ^xRRGGBB or ^7.\n"
        "- Keep the same NUMBER of placeholders as the source. Do not add or drop them. Do not convert # to a number.\n"
        "- Japanese may reorder placeholders naturally, but every placeholder token must still appear.\n"
        "- Output JSON only: an array of {\"id\":<int>,\"ja\":<string>}. No prose.\n"
    )
    items = json.dumps([{"id": i, "en": en} for i, en in enumerate(batch)], ensure_ascii=False)
    return f"{rules}\nEXAMPLES (house style):\n{ex}\n\nTranslate these to Japanese, return JSON array:\n{items}"

def call_gemini(prompt, keys, models):
    try:
        from google import genai
    except ImportError:
        return None, "google-genai SDK not installed"
    last = "no keys/models"
    for key in keys:
        try: client = genai.Client(api_key=key)
        except Exception as e: last = f"client init: {e}"; continue
        for model in models:
            try:
                resp = client.models.generate_content(
                    model=model, contents=prompt,
                    config={"response_mime_type": "application/json", "temperature": 0.0})
                txt = getattr(resp, "text", None) or ""
                data = json.loads(txt)
                return data, f"ok({model})"
            except Exception as e:
                last = f"{model}: {e}"; continue
    return None, last

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--n", type=int, default=30)
    ap.add_argument("--env", default=r"C:\Users\kyohei\youtube-pipeline\.env")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    try: sys.stdout.reconfigure(encoding="utf-8")
    except Exception: pass

    keys, models = load_env(args.env)
    print(f"keys={len(keys)} models={models}")
    if not keys: print("NO GEMINI KEYS FOUND"); sys.exit(2)

    rows = read_rows(args.csv)
    translated_pairs = [(r[0], r[1]) for r in rows if len(r) >= 2 and r[0] and r[0] != r[1]]
    untrans_idx = [i for i, r in enumerate(rows) if len(r) >= 2 and r[0] and r[0] == r[1]]
    # few-shot: 既訳から placeholder を含む例を優先して8件
    random.seed(7)
    ph_ex = [p for p in translated_pairs if ph_count(p[0]) >= 1]
    plain_ex = [p for p in translated_pairs if ph_count(p[0]) == 0]
    examples = (random.sample(ph_ex, min(5, len(ph_ex))) + random.sample(plain_ex, min(3, len(plain_ex))))
    # PoC対象: 未訳の先頭から n 件（再現性のため固定）
    pick = untrans_idx[:args.n]
    batch = [rows[i][0] for i in pick]
    print(f"untranslated total={len(untrans_idx)}  PoC batch={len(batch)}  few-shot={len(examples)}")

    data, status = call_gemini(build_prompt(batch, examples), keys, models)
    print("gemini:", status)
    if not data: print("FAILED"); sys.exit(1)

    by_id = {d["id"]: d.get("ja", "") for d in data if isinstance(d, dict)}
    ok = bad = 0; applied = 0
    print("\n=== 提案 (整合チェック付き) ===")
    for bi, ridx in enumerate(pick):
        en = rows[ridx][0]; ja = by_id.get(bi, "")
        reasons = []
        if not ja or ja == en: reasons.append("empty/echo")
        if ph_count(ja) != ph_count(en): reasons.append(f"ph#{ph_count(en)}->{ph_count(ja)}")
        if ph_set(ja) != ph_set(en): reasons.append("brace-set")
        if color_count(ja) != color_count(en): reasons.append("color")
        good = not reasons
        mark = "OK " if good else "NG "
        if good: ok += 1
        else: bad += 1
        print(f"  [{mark}] {en!r}\n        -> {ja!r}" + (f"   << {','.join(reasons)}" if reasons else ""))
        if good and args.apply:
            rows[ridx][1] = ja; applied += 1
    print(f"\n整合: OK {ok} / NG {bad} (採用率 {100*ok/max(ok+bad,1):.0f}%)")
    if args.apply and applied:
        bak = args.csv + ".poc-bak"
        if not os.path.exists(bak):
            with open(bak, "w", encoding="utf-8-sig", newline="") as d, open(args.csv, encoding="utf-8-sig") as s:
                d.write(s.read())
        with open(args.csv, "w", encoding="utf-8-sig", newline="") as f:
            csv.writer(f, lineterminator="\n").writerows(rows)
        print(f"APPLIED {applied} rows (.poc-bak saved)")

if __name__ == "__main__":
    main()
