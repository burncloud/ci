#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
check=$root/scripts/check-nested-workflow-pin.sh
names=(lint test supply-chain api protect)

expect_fail() {
  local name=$1
  local repo=$2
  local needle=$3
  local status=0
  local out
  out=$(bash "$check" "$repo" 2>&1) || status=$?
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL ${name}: 应当失败" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! grep -F -e "$needle" >/dev/null <<<"$out"; then
    echo "FAIL ${name}: 输出没有 ${needle}" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  echo "PASS ${name}"
}

write_rust() {
  local repo=$1
  local sha=$2
  local other=${3:-$sha}
  {
    printf '%s\n' 'on:' '  workflow_call:' 'jobs:'
    local name ref
    for name in "${names[@]}"; do
      ref=$sha
      if [[ "$name" == "protect" ]]; then
        ref=$other
      fi
      printf '  %s:\n    uses: burncloud/ci/.github/workflows/%s.yml@%s\n' "$name" "$name" "$ref"
    done
  } >"$repo/.github/workflows/rust.yml"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo
mkdir -p "$repo/.github/workflows"
git init -q -b main "$repo"
git -C "$repo" config user.email pin-test@example.com
git -C "$repo" config user.name pin-test
for name in "${names[@]}"; do
  printf 'name: %s\n' "$name" >"$repo/.github/workflows/${name}.yml"
done
write_rust "$repo" 0000000000000000000000000000000000000000
git -C "$repo" add .
git -C "$repo" commit -q -m base
base=$(git -C "$repo" rev-parse HEAD)
write_rust "$repo" "$base"
git -C "$repo" add .
git -C "$repo" commit -q -m pin
bash "$check" "$repo"
echo "PASS nested pin good"

write_rust "$repo" "$base" 1111111111111111111111111111111111111111
expect_fail mismatch "$repo" "sha 不一致"

write_rust "$repo" abcdef
expect_fail short "$repo" "不是 40 位小写十六进制"

git -C "$repo" checkout -q --orphan side
git -C "$repo" add .
git -C "$repo" commit -q -m side
side=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q main
write_rust "$repo" "$side"
expect_fail ancestor "$repo" "不是 HEAD 的祖先"

write_rust "$repo" "$base"
printf '\nextra\n' >>"$repo/.github/workflows/lint.yml"
expect_fail content "$repo" "内容不一致"
