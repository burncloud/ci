#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: run-clippy.sh WORKDIR" >&2
  exit 2
fi

wd=$1
if [[ ! -d "$wd" ]]; then
  echo "clippy: 目录不存在: ${wd}" >&2
  exit 1
fi
wd=$(cd "$wd" && pwd)
if [[ ! -f "$wd/Cargo.toml" ]]; then
  echo "clippy: ${wd} 下没有 Cargo.toml。" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cargo metadata --format-version 1 --no-deps --locked --manifest-path "$wd/Cargo.toml" >"$tmp/meta.json"

python3 - "$tmp/meta.json" "$tmp/plan" <<'PY'
import json
import sys
from pathlib import Path

meta = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
members = set(meta["workspace_members"])
nontest = []
seen_bench = []
has_lib = False
has_bin = False
has_example = False
has_test = False
for package in meta["packages"]:
    if package["id"] not in members:
        continue
    manifest = Path(package["manifest_path"])
    if ".burncloud-ci" in manifest.parts:
        continue
    for target in package["targets"]:
        kinds = target["kind"]
        if "custom-build" in kinds:
            continue
        if "lib" in kinds:
            has_lib = True
        if "bin" in kinds:
            has_bin = True
        if "example" in kinds:
            has_example = True
        if "bench" in kinds and target["name"] not in seen_bench:
            seen_bench.append(target["name"])
        if "test" in kinds or target.get("test") is True:
            has_test = True
if has_lib:
    nontest.append("--lib")
if has_bin:
    nontest.append("--bins")
if has_example:
    nontest.append("--examples")
for name in seen_bench:
    nontest.append("--bench")
    nontest.append(name)
lines = ["nontest", *nontest, "test"]
if has_test:
    lines.append("--tests")
Path(sys.argv[2]).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

mode=""
nontest_args=()
test_args=()
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    nontest)
      mode="nontest"
      ;;
    test)
      mode="test"
      ;;
    "")
      ;;
    *)
      if [[ "$mode" == "nontest" ]]; then
        nontest_args+=("$line")
      elif [[ "$mode" == "test" ]]; then
        test_args+=("$line")
      else
        echo "clippy: 无法解析目标。" >&2
        exit 1
      fi
      ;;
  esac
done <"$tmp/plan"

if [[ ${#nontest_args[@]} -eq 0 && ${#test_args[@]} -eq 0 ]]; then
  echo "clippy: 没有可检查的 target。" >&2
  exit 1
fi

strict=(
  -D warnings
  -W clippy::pedantic
  -D clippy::unwrap_used
  -D clippy::expect_used
  -D clippy::panic
  -D clippy::todo
  -D clippy::unimplemented
  -D clippy::wildcard_enum_match_arm
  -D clippy::allow_attributes_without_reason
  -D unused_must_use
  -D dead_code
)
relaxed=(
  -D warnings
  -W clippy::pedantic
  -A clippy::unwrap_used
  -A clippy::expect_used
  -A clippy::panic
  -A clippy::todo
  -A clippy::unimplemented
  -A clippy::wildcard_enum_match_arm
  -A clippy::allow_attributes_without_reason
  -D unused_must_use
  -D dead_code
)

export CARGO_TERM_COLOR=never
cd "$wd"
if [[ ${#nontest_args[@]} -gt 0 ]]; then
  echo "clippy: 非测试 ${nontest_args[*]}"
  cargo clippy --locked --workspace --all-features "${nontest_args[@]}" -- "${strict[@]}"
fi
if [[ ${#test_args[@]} -gt 0 ]]; then
  echo "clippy: 测试 ${test_args[*]}"
  cargo clippy --locked --workspace --all-features "${test_args[@]}" -- "${relaxed[@]}"
fi
