#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "用法: check-reusable-uses.sh DIR" >&2
  exit 2
fi

root=$1
if [[ ! -d "$root" ]]; then
  echo "reusable-uses: 目录不存在: ${root}" >&2
  exit 1
fi

shopt -s nullglob
files=("$root"/*.yml "$root"/*.yaml)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "reusable-uses: ${root} 下没有工作流文件。" >&2
  exit 1
fi

fail=0
for file in "${files[@]}"; do
  if ! grep -Eq '^[[:space:]]*workflow_call:[[:space:]]*$' "$file"; then
    continue
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ ! "$line" =~ ^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*(.+)$ ]]; then
      continue
    fi
    value="${BASH_REMATCH[1]}"
    value="${value%%#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ ${#value} -ge 2 && ( "$value" == \"*\" || "$value" == \'*\' ) ]]; then
      value="${value:1:${#value}-2}"
    fi
    if [[ "$value" == ./* ]]; then
      echo "reusable-uses: ${file} 可复用工作流不能使用 ${value}" >&2
      fail=1
    fi
  done <"$file"
done

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "reusable-uses: 已检查 ${root}"
