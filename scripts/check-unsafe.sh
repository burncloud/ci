#!/usr/bin/env bash
# 确认每个 lib/bin 根文件含有 #![forbid(unsafe_code)]，并拒绝源码里的 unsafe 整词。
# unsafe_code 这个标识符不含独立的 unsafe 单词，因此属性本身不会被第二次检查误伤。
set -euo pipefail

wd="${1:-.}"
wd=$(cd "$wd" && pwd)
manifest="$wd/Cargo.toml"

if [[ ! -f "$manifest" ]]; then
  echo "unsafe: ${wd} 下没有 Cargo.toml。" >&2
  exit 1
fi

metadata=$(cargo metadata --no-deps --format-version 1 --manifest-path "$manifest")
mapfile -t roots < <(printf '%s\n' "$metadata" | jq -r '.packages[].targets[] | select(any(.kind[]; . == "lib" or . == "bin")) | .src_path')

if [[ ${#roots[@]} -eq 0 ]]; then
  echo "unsafe: 没有找到 lib 或 bin 的 crate 根。" >&2
  exit 1
fi

missing=0
for root in "${roots[@]}"; do
  if [[ ! -f "$root" ]]; then
    echo "unsafe: crate 根不存在: ${root}" >&2
    missing=1
    continue
  fi
  if ! grep -Eq '^[[:space:]]*#!\[forbid\(unsafe_code\)\][[:space:]]*$' "$root"; then
    echo "unsafe: ${root} 缺少 #![forbid(unsafe_code)]。" >&2
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

if grep -RInw --include='*.rs' --exclude-dir=target --exclude-dir=.git -e unsafe "$wd"; then
  echo "unsafe: 上面的行含有 unsafe 关键字。" >&2
  exit 1
fi

echo "unsafe: 已检查 ${#roots[@]} 个 crate 根，源码中没有 unsafe 关键字。"
