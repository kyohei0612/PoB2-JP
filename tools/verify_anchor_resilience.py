#!/usr/bin/env python3
"""
verify_anchor_resilience.py — Phase 2 検証ハーネス（実機非破壊・作業コピーに対して実行）

PoB の新バージョンで Lua アンカーが変化した状況を「作業コピーの vanilla ファイルを人工改変」して再現し、
Install-PoB2-JP.ps1 の Phase 2 挙動（regex フォールバック救済 / data-only 縮退 / ループ非再発）を機械検証する。

Cases:
  F: フレッシュ適用（reset→install）で tier=full かつループ無し（Resolve-Anchor 実経路の回帰）。
  G: anchorB/C の literal を壊し regex でのみ当たる改変 → tier=full・マーカー存在（regex 救済）。
  H: UpdateCheck anchorC を削除（全戦略解決不能）→ tier=data-only・throwなし・
     Launch.lua に翻訳フック不在（半パッチゼロ）・CSV存在・ループ無し。
  I: 版 bump（manifest Version 変更）→ reset→install で tier=full・ループ無し（版遷移追従）。

使い方:
  python verify_anchor_resilience.py --root <PoB作業コピー> [--pwsh pwsh]
  ※ --root は壊して良い作業コピー（PoB2-JP-DEV 等）。実機を渡さないこと。
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.normpath(os.path.join(HERE, "..", "payload", "scripts"))
INSTALL = os.path.join(SCRIPTS, "Install-PoB2-JP.ps1")
RESET = os.path.join(SCRIPTS, "Reset-PoB2-JP.ps1")
VERIFY_LOOP = os.path.join(HERE, "verify_no_update_loop.py")


def run_ps(pwsh, script, *args):
    cmd = [pwsh, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script] + list(args)
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


# 各ケースが改変する vanilla ファイル。Case H は UpdateCheck.lua を .bak 無しで改変するため
# reset では戻らない。ケース間の汚染を断つためスナップショットを取り、各ケース冒頭で復元する。
SNAPSHOT_FILES = ["UpdateCheck.lua", "Launch.lua", os.path.join("Modules", "Main.lua"),
                  os.path.join("Modules", "Common.lua"), "manifest.xml"]
_SNAP = {}


def snapshot(root):
    for rel in SNAPSHOT_FILES:
        p = os.path.join(root, rel)
        if os.path.isfile(p):
            _SNAP[rel] = read(p)


def restore_snapshot(root):
    for rel, text in _SNAP.items():
        write(os.path.join(root, rel), text)


def reset(pwsh, root):
    return run_ps(pwsh, RESET, "-PoBRoot", root)


def install(pwsh, root):
    return run_ps(pwsh, INSTALL, "-PoBRoot", root, "-Force")


def read_state(root):
    p = os.path.join(root, ".pob2jp-state.json")
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8-sig") as f:
        return json.load(f)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def loops(root):
    """verify_no_update_loop.py を呼び loops 真偽を返す。"""
    p = subprocess.run([sys.executable, VERIFY_LOOP, "--root", root, "--json"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    try:
        return json.loads(p.stdout)["loops"]
    except Exception:
        return None


class Results:
    def __init__(self):
        self.rows = []

    def check(self, name, ok, detail=""):
        self.rows.append((name, bool(ok), detail))
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" :: {detail}" if detail else ""))
        return ok

    def summary(self):
        passed = sum(1 for _, ok, _ in self.rows if ok)
        print(f"\n===== {passed}/{len(self.rows)} checks passed =====")
        return all(ok for _, ok, _ in self.rows)


def case_F(pwsh, root, r):
    restore_snapshot(root)   # 前ケースが .bak 無しで残した改変を vanilla に戻す
    print("\n##### Case F: fresh apply (reset->install) = tier full, no loop #####")
    reset(pwsh, root)
    rc, out = install(pwsh, root)
    st = read_state(root)
    r.check("F.install-rc0", rc == 0, f"rc={rc}")
    r.check("F.tier-full", st and st.get("tier") == "full", str(st and st.get("tier")))
    uc = read(os.path.join(root, "UpdateCheck.lua"))
    r.check("F.updatecheck-marker", "pob2jp: load keep-list" in uc)
    r.check("F.no-loop", loops(root) is False)


def case_G(pwsh, root, r):
    restore_snapshot(root)
    print("\n##### Case G: literal broken, regex rescues = tier full #####")
    reset(pwsh, root)
    ucp = os.path.join(root, "UpdateCheck.lua")
    uc = read(ucp)
    # anchorB literal を壊す: "local updateFiles = { }" -> "local updateFiles  =  { }"
    uc2 = uc.replace("local updateFiles = { }", "local updateFiles  =  { }", 1)
    # anchorC literal を壊す: "if (not localFiles[name]" -> "if (not  localFiles[name]" (二重スペース)
    uc2 = uc2.replace("if (not localFiles[name]", "if (not  localFiles[name]", 1)
    changed = uc2 != uc
    write(ucp, uc2)
    r.check("G.precondition-mutated", changed, "anchors altered to break literals")
    rc, out = install(pwsh, root)
    st = read_state(root)
    r.check("G.install-rc0", rc == 0, f"rc={rc}")
    r.check("G.tier-full", st and st.get("tier") == "full", str(st and st.get("tier")))
    uc3 = read(ucp)
    r.check("G.updatecheck-marker", "pob2jp: load keep-list" in uc3)
    r.check("G.regex-logged", "method=regex" in (read(os.path.join(root, ".pob2jp-log.txt")) if os.path.isfile(os.path.join(root, ".pob2jp-log.txt")) else ""))
    r.check("G.no-loop", loops(root) is False)


def case_H(pwsh, root, r):
    restore_snapshot(root)
    print("\n##### Case H: anchorC removed (all strategies fail) = data-only degrade #####")
    reset(pwsh, root)
    ucp = os.path.join(root, "UpdateCheck.lua")
    uc = read(ucp)
    # anchorC（ループ本体先頭の if(...) then 行）を丸ごと削除して、literal も regex も当たらなくする
    uc2 = re.sub(r'[ \t]*if\s*\(\s*not\s+localFiles\[name\][\s\S]*?\)\s*then', '-- anchorC removed by test', uc, count=1)
    removed = uc2 != uc
    write(ucp, uc2)
    r.check("H.precondition-removed", removed, "anchorC deleted")
    rc, out = install(pwsh, root)
    st = read_state(root)
    r.check("H.install-rc0-no-throw", rc == 0, f"rc={rc}")
    r.check("H.tier-data-only", st and st.get("tier") == "data-only", str(st and st.get("tier")))
    launch = read(os.path.join(root, "Launch.lua"))
    r.check("H.no-half-patch", "poejpSafeTranslate" not in launch, "Launch.lua left vanilla (no hook)")
    r.check("H.csv-present", os.path.isdir(os.path.join(root, "Data", "Translate", "ja-JP")))
    r.check("H.no-loop", loops(root) is False)


def case_I(pwsh, root, r):
    restore_snapshot(root)
    print("\n##### Case I: version bump -> reset->install follows, tier full, no loop #####")
    reset(pwsh, root)
    manp = os.path.join(root, "manifest.xml")
    man = read(manp)
    m = re.search(r'(<Version number=")([^"]+)(")', man)
    bumped = False
    if m:
        parts = m.group(2).split(".")
        if len(parts) >= 2 and parts[1].isdigit():
            parts[1] = str(int(parts[1]) + 1)
            newver = ".".join(parts)
            man2 = man[:m.start(2)] + newver + man[m.end(2):]
            write(manp, man2)
            bumped = True
    r.check("I.precondition-bumped", bumped, "manifest Version minor +1")
    rc, out = install(pwsh, root)
    st = read_state(root)
    r.check("I.install-rc0", rc == 0, f"rc={rc}")
    r.check("I.tier-full", st and st.get("tier") == "full", str(st and st.get("tier")))
    r.check("I.no-loop", loops(root) is False)


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # cp932 コンソールでも安全に出力
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="壊して良いPoB作業コピー（実機禁止）")
    ap.add_argument("--pwsh", default="pwsh")
    ap.add_argument("--only", default=None, help="F/G/H/I のいずれかだけ実行")
    args = ap.parse_args()

    if not os.path.isfile(os.path.join(args.root, "UpdateCheck.lua")):
        print(f"ERROR: not a PoB root: {args.root}")
        sys.exit(2)

    # vanilla スナップショットを取得（初回 reset で原本化してから）。ケース間の汚染遮断に使う。
    reset(args.pwsh, args.root)
    snapshot(args.root)

    r = Results()
    cases = {"F": case_F, "G": case_G, "H": case_H, "I": case_I}
    keys = [args.only] if args.only else ["F", "G", "H", "I"]
    for k in keys:
        cases[k](args.pwsh, args.root, r)
    # 後始末: vanilla を復元（Case H は UpdateCheck を .bak 無しで改変するため snapshot で戻す）→
    # reset で JP痕跡を掃除 → 通常の full 状態へ再適用して DEV をクリーンな使用可能状態で残す。
    restore_snapshot(args.root)
    reset(args.pwsh, args.root)
    install(args.pwsh, args.root)
    ok = r.summary()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
