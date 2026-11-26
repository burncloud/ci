#!/usr/bin/env bash
set -euo pipefail

wd=${WORKING_DIRECTORY:-.}
wd=${wd#./}
mode=${SEMVER_BASELINE:-auto}
base_sha=${BASE_SHA:-}

cargo semver-checks --version

if [[ "$mode" == "auto" ]]; then
  if [[ -n "$base_sha" ]]; then
    mode=base
  else
    mode=tag
  fi
fi

rev=""
case "$mode" in
  base)
    if [[ -z "$base_sha" ]]; then
      echo "semver: baseline=base，但当前事件没有 pull request 的 base sha。" >&2
      exit 1
    fi
    rev=$base_sha
    ;;
  tag)
    rev=$(git tag --list 'v*' --sort=-v:refname | head -n 1 || true)
    if [[ -z "$rev" ]]; then
      rev=$(git tag --sort=-creatordate | head -n 1 || true)
    fi
    if [[ -z "$rev" ]]; then
      if [[ "${SEMVER_BASELINE:-auto}" == "auto" ]]; then
        echo "semver: 没有 pull request base，也没有 tag，视为新 crate，跳过。"
        exit 0
      fi
      echo "semver: baseline=tag，但仓库没有任何 tag。" >&2
      exit 1
    fi
    ;;
  *)
    rev=$mode
    ;;
esac

if ! git rev-parse --verify --quiet "${rev}^{commit}" >/dev/null; then
  echo "semver: 无法解析基线 ${rev}。需要完整 git 历史。" >&2
  exit 1
fi

if [[ "$wd" == "." || -z "$wd" ]]; then
  manifest=Cargo.toml
else
  manifest=${wd}/Cargo.toml
fi

if ! git cat-file -e "${rev}:${manifest}" 2>/dev/null; then
  echo "semver: 基线 ${rev} 上不存在 ${manifest}，视为新 crate，跳过。"
  exit 0
fi

tmp=$(mktemp -d)
baseline_wt=""
cleanup() {
  status=$?
  if [[ -n "$baseline_wt" ]]; then
    git worktree remove --force "$baseline_wt" >/dev/null 2>&1 || true
    git worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT

list_libs() {
  local manifest_path=$1
  local out=$2
  cargo metadata --format-version 1 --no-deps --offline --manifest-path "$manifest_path" >"$tmp/meta.json"
  python3 - "$tmp/meta.json" "$out" <<'PY'
import json
import sys
from pathlib import Path

kinds = {"lib", "rlib", "dylib", "cdylib", "staticlib"}
meta = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
members = set(meta["workspace_members"])
names = []
for package in meta["packages"]:
    if package["id"] not in members:
        continue
    for target in package["targets"]:
        if kinds.intersection(target["kind"]):
            names.append(package["name"])
            break
names = sorted(set(names))
Path(sys.argv[2]).write_text("".join(f"{name}\n" for name in names), encoding="utf-8")
PY
}

has_name() {
  local name=$1
  local file=$2
  grep -Fxq -- "$name" "$file"
}

echo "semver: 对比 ${rev} (${manifest})"
list_libs "$manifest" "$tmp/current.txt"

baseline_wt="${tmp}/baseline"
git worktree add --quiet --detach "$baseline_wt" "$rev"
list_libs "${baseline_wt}/${manifest}" "$tmp/baseline.txt"

echo "semver: 基线库包: $(tr '\n' ' ' <"$tmp/baseline.txt")"
echo "semver: 当前库包: $(tr '\n' ' ' <"$tmp/current.txt")"

while IFS= read -r name || [[ -n "$name" ]]; do
  [[ -z "$name" ]] && continue
  if ! has_name "$name" "$tmp/baseline.txt"; then
    echo "新增包，无基线: ${name}"
  fi
done <"$tmp/current.txt"

removed=0
while IFS= read -r name || [[ -n "$name" ]]; do
  [[ -z "$name" ]] && continue
  if ! has_name "$name" "$tmp/current.txt"; then
    echo "semver: 包 ${name} 在基线存在、当前不存在，算破坏性改动。" >&2
    removed=1
  fi
done <"$tmp/baseline.txt"

while IFS= read -r name || [[ -n "$name" ]]; do
  [[ -z "$name" ]] && continue
  if has_name "$name" "$tmp/baseline.txt"; then
    echo "semver: --package ${name}"
    cargo semver-checks --baseline-rev "$rev" --manifest-path "$manifest" --package "$name"
  fi
done <"$tmp/current.txt"

if [[ "$removed" -ne 0 ]]; then
  exit 1
fi
