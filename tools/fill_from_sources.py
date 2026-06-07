#!/usr/bin/env python3
"""
fill_from_sources.py — Phase 3.1 安全lookup充填

ExileDesk のローカルJA源から EN->JA マスター辞書を構築し、PoB2-JP の CSV辞書
(payload/Data/Translate/ja-JP/*.csv) の「未訳行(EN==JA)」だけを安全に埋める。

安全規則（誤訳ゼロ＝No Compromise）:
  - 既訳行(JA!=EN)は絶対に上書きしない。EN==JA の行のみ対象。
  - 完全一致: source JA を採用。ただし EN と JA の {n} プレースホルダ集合が一致する時のみ
    （名前など placeholder 無し行は常に安全）。
  - 正規化一致: source JA は '#' を使うため、EN の {n} が 0個 or 1個 の時のみ採用
    （複数 {n} は日本語の語順入替で番号取り違え＝誤訳になるため除外）。
    1個の時は JA 内の単一 '#' を EN の placeholder トークン({0}等)へ復元。
  - 色コード ^xRRGGBB / ^7 等を含む EN 行は、source 側に同コードが無ければ skip（表示崩れ回避）。

使い方:
  python fill_from_sources.py --jp <ja-JP dir> --exiledesk <ExileDesk root> [--apply] [--report out.json]
  既定は dry-run（書き込まない）。--apply で実書込（.bak を1度だけ作成）。
"""
import argparse, csv, glob, json, os, re, sys

def loadj(p):
    try:
        with open(p, encoding="utf-8-sig") as f: return json.load(f)
    except Exception: return None

PH = re.compile(r"\{(\d+)\}")

def ph_set(s): return set(PH.findall(s))
def ph_count(s): return len(PH.findall(s)) + s.count("#")  # PoB は {n} と # の両方を placeholder に使う

def build_master(E):
    M = {}
    def add(en, ja):
        if isinstance(en, str) and isinstance(ja, str) and en and ja and en != ja:
            M.setdefault(en, ja)
    for rel in ["src/i18n/unique-names-ja.json", "src/i18n/items-ja.json",
                "src/i18n/mod-text-ja.json", "src/i18n/mod-text-ja-manual.json",
                "src/i18n/unique-mods-ja.json"]:
        d = loadj(os.path.join(E, rel))
        if isinstance(d, dict):
            for k, v in d.items():
                if isinstance(v, str): add(k, v)
                elif isinstance(v, dict):
                    for k2, v2 in v.items():
                        if isinstance(v2, str): add(k2, v2)
    men, mja = loadj(os.path.join(E, "data-cache/mods.en.json")), loadj(os.path.join(E, "data-cache/mods.ja.json"))
    if isinstance(men, dict) and isinstance(mja, dict):
        for i, e in men.items():
            if i in mja and isinstance(e, dict): add(e.get("name"), mja[i].get("name"))
    def trade(fn):
        d = loadj(os.path.join(E, "data-cache", fn)); out = {}
        if d:
            for g in d["result"]:
                for x in g["entries"]: out[x["id"]] = x["text"]
        return out
    te, tj = trade("trade2-stats-en.json"), trade("trade2-stats-jp.json")
    for i, t in te.items():
        if i in tj: add(t, tj[i])
    fe, fj = loadj(os.path.join(E, "data-cache/repoe-flavour-en.json")), loadj(os.path.join(E, "data-cache/repoe-flavour-ja.json"))
    if isinstance(fe, dict) and isinstance(fj, dict):
        for k, e in fe.items():
            if k in fj and isinstance(e, str): add(e, fj[k])
    return M

def norm(s):
    s = s.replace("’", "'")
    s = re.sub(r"[\(\[]\d+(\.\d+)?[-–]\d+(\.\d+)?[\)\]]", "#", s)
    s = re.sub(r"\{\d+\}", "#", s)
    s = re.sub(r"\b\d+(\.\d+)?\b", "#", s)
    s = re.sub(r"[+]?#%?", "#", s)
    s = re.sub(r"[#\s]+", " ", s)
    return s.lower().strip()

def lookup(en, M, Mn):
    # returns (ja, method) or (None, reason)
    has_color = "^" in en
    eph = ph_set(en)          # EN 内の {n} 集合
    ec = ph_count(en)         # EN の placeholder 総数（{n} + #）
    # 1) 完全一致: placeholder 総数も {n} 集合も完全一致する時のみ（焼き込み値や個数不一致を排除）
    if en in M:
        ja = M[en]
        if ph_count(ja) == ec and ph_set(ja) == eph and not (has_color and "^" not in ja):
            return ja, "exact"
        return None, "exact-ph-mismatch"
    # 2) 正規化一致（source JA は基本 '#' 表記）
    j = Mn.get(norm(en))
    if j is None:
        return None, "no-match"
    if has_color and "^" not in j:
        return None, "color-skip"
    if ph_count(j) != ec:
        return None, "placeholder-count-mismatch"   # 焼き込み数値(例 +100)や個数違いを排除
    if eph:
        # EN が {n} を使う。source は '#'。安全なのは「placeholder が単一」の時だけ（複数は語順入替リスク）
        if ec != 1 or ph_set(j):
            return None, "brace-remap-unsafe"
        if j.count("#") != 1:
            return None, "remap-count"
        return j.replace("#", "{%s}" % sorted(eph)[0], 1), "normalized"
    else:
        # EN が '#'（or placeholder無し）。JA も同表記であること（余計な {n} が無い）
        if ph_set(j):
            return None, "ja-unexpected-brace"
        return j, "normalized"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jp", required=True)
    ap.add_argument("--exiledesk", required=True)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--report", default=None)
    args = ap.parse_args()
    try: sys.stdout.reconfigure(encoding="utf-8")
    except Exception: pass

    M = build_master(args.exiledesk)
    Mn = {norm(k): v for k, v in M.items()}
    print(f"master EN->JA: {len(M)}")

    total_un = 0; total_fill = 0; reasons = {}; per = {}; samples = []
    for path in sorted(glob.glob(os.path.join(args.jp, "*.csv"))):
        name = os.path.basename(path)
        with open(path, encoding="utf-8-sig", newline="") as f:
            rows = list(csv.reader(f))
        filled = 0; changed = False
        for r in rows:
            if len(r) < 2 or not r[0]: continue
            en, ja = r[0], r[1]
            if en != ja: continue
            total_un += 1
            res, why = lookup(en, M, Mn)
            if res is not None and res != en:
                if len(samples) < 25: samples.append((name, en, res, why))
                r[1] = res; filled += 1; changed = True
            else:
                reasons[why] = reasons.get(why, 0) + 1
        if filled:
            per[name] = filled; total_fill += filled
        if changed and args.apply:
            bak = path + ".pre-fill.bak"
            if not os.path.exists(bak):
                with open(path, encoding="utf-8-sig") as src, open(bak, "w", encoding="utf-8-sig", newline="") as dst:
                    dst.write(src.read())
            with open(path, "w", encoding="utf-8-sig", newline="") as f:
                w = csv.writer(f, lineterminator="\n")
                w.writerows(rows)
    print(f"未訳 {total_un} / 安全充填 {total_fill} ({100*total_fill/max(total_un,1):.2f}%)  [{'APPLIED' if args.apply else 'DRY-RUN'}]")
    print("充填 per CSV:", dict(sorted(per.items(), key=lambda kv: -kv[1])))
    print("非充填理由 上位:", dict(sorted(reasons.items(), key=lambda kv: -kv[1])[:8]))
    print("\n充填サンプル:")
    for n, en, ja, why in samples[:20]:
        print(f"  [{why}] {n}: {en!r} -> {ja!r}")
    if args.report:
        json.dump({"untranslated": total_un, "filled": total_fill, "per_csv": per, "reasons": reasons},
                  open(args.report, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

if __name__ == "__main__":
    main()
