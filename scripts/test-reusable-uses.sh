#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
check=$root/scripts/check-reusable-uses.sh
fix=tests/reusable-uses

expect_fail() {
  local name=$1
  local dir=$2
  local needle=$3
  local status=0
  local out
  out=$(bash "$check" "$root/$dir" 2>&1) || status=$?
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

bash "$check" "$root/.github/workflows"
bash "$check" "$root/$fix/same-repo"
bash "$check" "$root/$fix/caller"
echo "PASS reusable allow"

expect_fail relative "$fix/relative" "./.github/workflows/supply-chain.yml"
expect_fail quoted "$fix/quoted" "./.github/workflows/api.yml"
expect_fail dollar "$fix/dollar" "\$/.github/workflows/lint.yml"
expect_fail list "$fix/flow-list" "./.github/workflows/protect.yml"
expect_fail plain "$fix/flow-plain" "\$/.github/workflows/test.yml"
expect_fail empty "$fix/flow-empty" "./.github/workflows/api.yml"
expect_fail latest "$fix/latest" "必须钉 40 位小写 sha"
