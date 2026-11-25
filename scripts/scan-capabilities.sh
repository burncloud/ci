#!/usr/bin/env bash
# 占位：列出可能触达文件系统、网络、进程和环境的标准库路径。只报告，始终成功。
set -euo pipefail

wd="${1:-.}"
if [[ ! -d "$wd" ]]; then
  echo "capabilities: 目录不存在: ${wd}" >&2
  exit 1
fi

patterns=(
  'std::fs'
  'std::net'
  'std::process'
  'std::env'
  'std::thread'
  'std::os'
  'tokio::fs'
  'tokio::net'
  'tokio::process'
)

echo "capabilities: 占位报告。当前只统计下面这些路径，不阻断。"
for pattern in "${patterns[@]}"; do
  matches=$(grep -RIn --include='*.rs' --exclude-dir=target --exclude-dir=.git --exclude-dir=.burncloud-ci -F -e "$pattern" "$wd" || true)
  if [[ -z "$matches" ]]; then
    echo "${pattern}: 0"
    continue
  fi
  count=$(printf '%s\n' "$matches" | wc -l)
  count=${count//[[:space:]]/}
  echo "${pattern}: ${count}"
  printf '%s\n' "$matches" | head -n 100
  if [[ "$count" -gt 100 ]]; then
    echo "${pattern}: 其余 $((count - 100)) 行已省略"
  fi
done
