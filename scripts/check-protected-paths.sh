#!/usr/bin/env bash
# 只根据调用方给出的路径列表和 Cargo.toml 文本判断，不读取 git 工作区。
set -euo pipefail

print_defaults() {
  cat <<'EOF'
.github/
contracts/
supply-chain/
clippy.toml
rustfmt.toml
deny.toml
rust-toolchain
rust-toolchain.toml
Cargo.toml[lints]
EOF
}

usage() {
  echo "usage: check-protected-paths.sh --changed FILE [--paths FILE] [--lints FILE] [--exempt] [--print-defaults]" >&2
}

changed=""
paths_file=""
lints_file=""
exempt=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --changed)
      changed=$2
      shift 2
      ;;
    --paths)
      paths_file=$2
      shift 2
      ;;
    --lints)
      lints_file=$2
      shift 2
      ;;
    --exempt)
      exempt=1
      shift
      ;;
    --print-defaults)
      print_defaults
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$changed" || ! -f "$changed" ]]; then
  usage
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [[ -n "$paths_file" ]]; then
  cp "$paths_file" "$tmp/paths"
else
  print_defaults >"$tmp/paths"
fi

# 去掉空行和注释，避免 input 里的空行把默认值冲掉之后无法判断。
grep -Ev '^[[:space:]]*(#|$)' "$tmp/paths" >"$tmp/patterns" || true

extract_lints() {
  local file=$1
  if [[ ! -s "$file" ]]; then
    return 0
  fi
  awk '
    /^\[/ {
      capture = ($0 ~ /^\[lints(\.|])/)
    }
    capture { print }
  ' "$file" | sed -e 's/[[:space:]]*$//' -e '/^$/d'
}

check_lints=0
if grep -Fxq 'Cargo.toml[lints]' "$tmp/patterns"; then
  check_lints=1
fi

hits=0
while IFS= read -r path || [[ -n "$path" ]]; do
  [[ -z "$path" ]] && continue
  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    [[ -z "$pattern" || "$pattern" == "Cargo.toml[lints]" ]] && continue
    matched=0
    if [[ "$pattern" == */ ]]; then
      prefix=${pattern%/}
      if [[ "$path" == "$prefix" || "$path" == "$prefix"/* ]]; then
        matched=1
      fi
    elif [[ "$pattern" == */* ]]; then
      if [[ "$path" == "$pattern" || "$path" == "$pattern"* ]]; then
        matched=1
      fi
    elif [[ "$path" == "$pattern" || "$path" == */"$pattern" ]]; then
      matched=1
    fi
    if [[ "$matched" -eq 1 ]]; then
      echo "protected: ${path} 匹配 ${pattern}"
      hits=1
    fi
  done <"$tmp/patterns"
done <"$changed"

if [[ "$check_lints" -eq 1 ]]; then
  if [[ -n "$lints_file" ]]; then
    while IFS='|' read -r path before after; do
      [[ -z "${path:-}" ]] && continue
      if [[ -z "${before:-}" || -z "${after:-}" || ! -f "$before" || ! -f "$after" ]]; then
        echo "protected: ${path} 缺少用于比较 [lints] 的文件内容，拒绝放行。" >&2
        hits=1
        continue
      fi
      extract_lints "$before" >"$tmp/before"
      extract_lints "$after" >"$tmp/after"
      if ! cmp -s "$tmp/before" "$tmp/after"; then
        echo "protected: ${path} 的 [lints] 表发生了变化"
        hits=1
      fi
    done <"$lints_file"
  fi

  while IFS= read -r path || [[ -n "$path" ]]; do
    base=$(basename "$path")
    if [[ "$base" != "Cargo.toml" ]]; then
      continue
    fi
    if [[ -z "$lints_file" ]] || ! awk -F'|' -v path="$path" '$1 == path { found = 1 } END { exit !found }' "$lints_file"; then
      echo "protected: ${path} 有改动，但没有提供内容来判断 [lints]，拒绝放行。" >&2
      hits=1
    fi
  done <"$changed"
fi

if [[ "$hits" -eq 0 ]]; then
  echo "protected: 没有命中受保护路径。"
  exit 0
fi

if [[ "$exempt" -eq 1 ]]; then
  echo "protected: 当前仓库是工作流定义仓库，且变更来自同一仓库。命中项已记录，不阻断。其他仓库会失败。"
  exit 0
fi

echo "protected: 受保护路径被修改，检查失败。" >&2
exit 1
