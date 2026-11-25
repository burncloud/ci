#!/usr/bin/env bash
# 固定版本：40 位提交 SHA，或 vX.Y.Z。
# SHA 接受大小写十六进制。v 只小写。浮动标签和分支名拒绝。
set -euo pipefail

pinned_ref_re='^([0-9a-fA-F]{40}|v[0-9]+\.[0-9]+\.[0-9]+)$'

is_pinned_ref() {
  local ref=$1
  [[ "$ref" =~ $pinned_ref_re ]]
}

if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  echo "用法: check-pinned-ref.sh <ref>" >&2
  exit 2
fi

if is_pinned_ref "$1"; then
  exit 0
fi
echo "不是固定版本: $1" >&2
exit 1
