#!/usr/bin/env bash
# 优先使用仓库里的 rust-toolchain 文件，没有才用 TOOLCHAIN 输入。
# 结果写到 GITHUB_OUTPUT 的 toolchain。
set -euo pipefail

wd=${WORKING_DIRECTORY:-.}
channel=""
file=""
for candidate in rust-toolchain.toml rust-toolchain "${wd}/rust-toolchain.toml" "${wd}/rust-toolchain"; do
  if [[ -f "$candidate" ]]; then
    file=$candidate
    break
  fi
done

if [[ -n "$file" ]]; then
  if [[ "$file" == *.toml ]]; then
    channel=$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$file" | head -n 1)
  else
    channel=$(head -n 1 "$file" | tr -d '[:space:]')
  fi
  if [[ -z "$channel" ]]; then
    echo "无法从 ${file} 解析 channel。" >&2
    exit 1
  fi
  echo "使用 ${file} 里的 toolchain ${channel}。"
elif [[ -n "${TOOLCHAIN:-}" ]]; then
  channel=$TOOLCHAIN
  echo "仓库没有 rust-toolchain 文件，使用输入 toolchain ${channel}。"
else
  echo "没有 rust-toolchain.toml，也没有 toolchain 输入。请在仓库根提交并保护 rust-toolchain.toml。" >&2
  exit 1
fi

if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
  printf '%s\n' "$channel"
  exit 0
fi
echo "toolchain=${channel}" >>"$GITHUB_OUTPUT"
