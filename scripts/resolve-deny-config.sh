#!/usr/bin/env bash
# 把要用的 deny.toml 路径打到 stdout。说明写到 stderr。
# DEFAULT_DENY 指向工作流仓库里的默认文件，由 checkout 得到，不再从 raw.githubusercontent.com 下载。
set -euo pipefail

wd=${1:-.}
wd=$(cd "$wd" && pwd)
workspace=${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}
workspace=$(cd "$workspace" && pwd)

dir=$wd
found=""
while true; do
  if [[ -f "$dir/deny.toml" ]]; then
    found=$dir/deny.toml
    break
  fi
  if [[ "$dir" == "$workspace" || "$dir" == "/" ]]; then
    break
  fi
  dir=$(dirname "$dir")
done

if [[ -n "$found" ]]; then
  echo "cargo-deny: 使用调用方配置 ${found}" >&2
  printf '%s\n' "$found"
  exit 0
fi

if [[ -n "${DEFAULT_DENY:-}" && -f "$DEFAULT_DENY" ]]; then
  echo "cargo-deny: 调用方没有 deny.toml，使用工作流仓库里的 ${DEFAULT_DENY}" >&2
  printf '%s\n' "$DEFAULT_DENY"
  exit 0
fi

echo "cargo-deny: 调用方没有 deny.toml，也没有默认配置文件。" >&2
exit 1
