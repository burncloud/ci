#!/usr/bin/env bash
# 用 Cargo 清单里的 [lints.rust] unsafe_code = "forbid" 要求编译器拒绝 unsafe。
# 不扫描源码文本。需要 unsafe 的 crate 把包名写进受保护的 unsafe-crates.txt。
set -euo pipefail

wd="${1:-.}"
wd=$(cd "$wd" && pwd)
manifest="$wd/Cargo.toml"

if [[ ! -f "$manifest" ]]; then
  echo "unsafe: ${wd} 下没有 Cargo.toml。" >&2
  exit 1
fi

export CHECK_UNSAFE_WD="$wd"
export CHECK_UNSAFE_MANIFEST="$manifest"
python3 - <<'PY'
import os
import subprocess
import sys
import tomllib
from pathlib import Path

wd = Path(os.environ["CHECK_UNSAFE_WD"])
manifest = Path(os.environ["CHECK_UNSAFE_MANIFEST"])

def load_names(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    names = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            names.add(line)
    return names

exempt = set()
for candidate in (wd / "unsafe-crates.txt",):
    exempt |= load_names(candidate)
workspace_env = os.environ.get("GITHUB_WORKSPACE")
if workspace_env:
    root_list = Path(workspace_env) / "unsafe-crates.txt"
    if root_list != wd / "unsafe-crates.txt":
        exempt |= load_names(root_list)

meta = subprocess.check_output(
    [
        "cargo",
        "metadata",
        "--no-deps",
        "--format-version",
        "1",
        "--manifest-path",
        str(manifest),
    ],
    text=True,
)
import json

packages = json.loads(meta)["packages"]
manifests = {}
for package in packages:
    path = Path(package["manifest_path"])
    if ".burncloud-ci" in path.parts:
        continue
    manifests[path] = package["name"]

def read_toml(path: Path) -> dict:
    return tomllib.loads(path.read_text(encoding="utf-8"))

def level_of(lints: object) -> str | None:
    if not isinstance(lints, dict):
        return None
    rust = lints.get("rust")
    if not isinstance(rust, dict):
        return None
    value = rust.get("unsafe_code")
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        inner = value.get("level")
        if isinstance(inner, str):
            return inner
    return None

def forbidden(package_manifest: Path, package_doc: dict) -> bool:
    lints = package_doc.get("lints")
    if isinstance(lints, dict) and lints.get("workspace") is True:
        root = package_manifest
        while True:
            candidate = root / "Cargo.toml"
            if candidate.is_file() and candidate != package_manifest:
                workspace_doc = read_toml(candidate)
                workspace = workspace_doc.get("workspace")
                if isinstance(workspace, dict):
                    return level_of(workspace.get("lints")) == "forbid"
            if root.parent == root:
                break
            root = root.parent
        return False
    return level_of(lints) == "forbid"

failed = False
for path, name in sorted(manifests.items(), key=lambda item: item[1]):
    if name in exempt:
        print(f"unsafe: {name} 在 unsafe-crates.txt 中，跳过 forbid 要求。")
        continue
    doc = read_toml(path)
    if forbidden(path, doc):
        print(f"unsafe: {name} 的清单要求编译器 forbid(unsafe_code)。")
        continue
    print(
        f"unsafe: {name} ({path}) 没有 [lints.rust] unsafe_code = \"forbid\"，也没有列入 unsafe-crates.txt。",
        file=sys.stderr,
    )
    failed = True

if failed:
    sys.exit(1)
print(f"unsafe: 已核验 {len(manifests)} 个 crate 的清单。")
PY
