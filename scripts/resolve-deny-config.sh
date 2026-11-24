#!/usr/bin/env bash
# 把要用的 deny.toml 路径打到 stdout。说明写到 stderr。
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

repo=${WORKFLOW_REPO:-}
sha=${WORKFLOW_SHA:-}
if [[ -z "$repo" || -z "$sha" ]]; then
  echo "cargo-deny: 调用方没有 deny.toml，且没有 WORKFLOW_REPO / WORKFLOW_SHA，无法下载默认配置。" >&2
  exit 1
fi

dest=${RUNNER_TEMP:-/tmp}/burncloud-deny.toml
url="https://raw.githubusercontent.com/${repo}/${sha}/deny.toml"
echo "cargo-deny: 调用方没有 deny.toml，下载 ${url}" >&2
curl -fsSL "$url" -o "$dest"
printf '%s\n' "$dest"
