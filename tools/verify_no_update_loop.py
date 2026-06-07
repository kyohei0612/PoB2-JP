#!/usr/bin/env python3
"""
verify_no_update_loop.py — GUIを起動せずに PoB の更新判定を忠実再現し、
PoB2-JP のループ抑止が効いているかを機械検証する。

PoB の UpdateCheck.lua (L177-210) の updateFiles 構築ロジックを移植し、
さらに PoB2-JP パッチが加える「keep + remoteVer==localVer ガード」も再現する。
ネット不要（remote manifest は local manifest を fixture として流用）。

判定:
  - updateFiles が空            → ループ無し (OK)
  - updateFiles に part=runtime → basic更新モード = Exit再起動ループの原因
使い方:
  python verify_no_update_loop.py --root <PoBRoot> [--bump] [--no-keep] [--json]

  --root     PoB ルート（manifest.xml / UpdateCheck.lua がある所）
  --bump     リモートを新バージョン扱い（Version を +0.1）→ 本物更新の追従を検証
  --no-keep  keep を無視（=パッチ前の現状/対照）→ ループ再現を確認
  --json     結果を JSON で出力
"""
import argparse
import hashlib
import json
import os
import sys
import xml.etree.ElementTree as ET


def sha1_variants(path):
    """UpdateCheck.lua と同じ CRLF 寛容 sha1（生 / \\n->\\r\\n の両方）。"""
    with open(path, "rb") as f:
        b = f.read()
    h1 = hashlib.sha1(b).hexdigest()
    h2 = hashlib.sha1(b.replace(b"\n", b"\r\n")).hexdigest()
    return {h1, h2}


def parse_manifest(path):
    """manifest.xml -> (version, {name(生表記): {'sha1','part'}})"""
    root = ET.parse(path).getroot()
    version = None
    files = {}
    for node in root:
        if node.tag == "Version":
            version = node.get("number")
        elif node.tag == "File":
            files[node.get("name")] = {
                "sha1": (node.get("sha1") or "").lower(),
                "part": node.get("part"),
            }
    return version, files


def load_keep(root):
    p = os.path.join(root, ".pob2jp-keep.txt")
    keep = set()
    if os.path.isfile(p):
        with open(p, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    keep.add(line)
    return keep


def bump_version(v):
    """0.19.0 -> 0.20.0 のように minor を +1（新バージョン擬似）。"""
    parts = (v or "0.0.0").split(".")
    while len(parts) < 2:
        parts.append("0")
    try:
        parts[1] = str(int(parts[1]) + 1)
    except ValueError:
        parts[1] = parts[1] + "x"
    return ".".join(parts)


def resolve_path(root, name):
    # この作業コピーは runtimePath == scriptPath == root。name の {space} を実体へ。
    return os.path.join(root, name.replace("{space}", " "))


def simulate(root, use_keep=True, bump=False):
    man_path = os.path.join(root, "manifest.xml")
    local_ver, local_files = parse_manifest(man_path)
    # remote manifest は local を fixture 流用（PoB の比較は sha1 ベース）
    remote_ver = bump_version(local_ver) if bump else local_ver
    remote_files = local_files  # 同一バージョン時は完全同一。bump時も sha1 は据置(原本)。

    keep = load_keep(root) if use_keep else set()
    version_changed = (local_ver != remote_ver)

    update_files = []   # [(name, part, reason)]
    for name, rdata in remote_files.items():
        # --- PoB2-JP パッチの再現: 同一バージョンなら keep ファイルを除外 ---
        if name in keep and not version_changed:
            continue
        rsha = rdata["sha1"]
        ldata = local_files.get(name)
        sanitized = name.replace("{space}", " ")
        ldata_s = local_files.get(sanitized)
        # L181: local manifest sha1 vs remote manifest sha1
        cond = (ldata is None or ldata["sha1"] != rsha) and (
            ldata_s is None or ldata_s["sha1"] != rsha
        )
        if cond:
            update_files.append((name, rdata["part"], "manifest-sha1-diff"))
        elif ldata is not None:
            # L184-195: 実ファイル sha1 を再計算（整合性チェック）
            abs_path = resolve_path(root, name)
            if not os.path.exists(abs_path):
                update_files.append((name, rdata["part"], "missing-file"))
            else:
                if rsha not in sha1_variants(abs_path):
                    update_files.append((name, rdata["part"], "integrity-fail"))

    runtime_hits = [u for u in update_files if u[1] == "runtime"]
    if runtime_hits:
        update_mode = "basic"     # part=runtime が混じる → basic（Exit再起動）
    elif update_files:
        update_mode = "normal"
    else:
        update_mode = "none"

    return {
        "local_version": local_ver,
        "remote_version": remote_ver,
        "version_changed": version_changed,
        "use_keep": use_keep,
        "keep_count": len(keep),
        "update_count": len(update_files),
        "runtime_in_update": len(runtime_hits),
        "update_mode": update_mode,
        "loops": update_mode == "basic",     # 実害 = basic 再起動ループ
        "updates": [{"name": n, "part": p, "reason": r} for n, p, r in update_files],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--bump", action="store_true")
    ap.add_argument("--no-keep", dest="use_keep", action="store_false")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    res = simulate(args.root, use_keep=args.use_keep, bump=args.bump)
    if args.json:
        print(json.dumps(res, ensure_ascii=False, indent=2))
        return
    print(f"local={res['local_version']} remote={res['remote_version']} "
          f"versionChanged={res['version_changed']} keep={res['keep_count']} "
          f"useKeep={res['use_keep']}")
    print(f"updateMode={res['update_mode']} updateCount={res['update_count']} "
          f"runtimeInUpdate={res['runtime_in_update']} LOOPS={res['loops']}")
    for u in res["updates"][:30]:
        print(f"  [{u['part']}] {u['name']} ({u['reason']})")
    if res["update_count"] > 30:
        print(f"  ... +{res['update_count']-30} more")


if __name__ == "__main__":
    main()
