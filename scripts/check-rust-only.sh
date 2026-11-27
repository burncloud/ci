#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: check-rust-only.sh [--exempt] [DIR]" >&2
}

exempt=0
dir=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exempt)
      exempt=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      if [[ -n "$dir" ]]; then
        usage
        exit 2
      fi
      dir=$1
      shift
      ;;
  esac
done

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi
if [[ $# -eq 1 ]]; then
  if [[ -n "$dir" ]]; then
    usage
    exit 2
  fi
  dir=$1
fi

if [[ -z "$dir" ]]; then
  dir=.
fi

if [[ ! -d "$dir" ]]; then
  echo "rust-only: 目录不存在: ${dir}" >&2
  exit 2
fi

toplevel=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || {
  echo "rust-only: 不是 git 仓库: ${dir}" >&2
  exit 2
}

allowed() {
  local path=$1
  local base=${path##*/}
  case "$base" in
    *.rs | Cargo.toml | Cargo.lock | rust-toolchain | rust-toolchain.toml | *.toml | *.md | .gitignore | LICENSE*)
      return 0
      ;;
  esac
  case "$path" in
    .github/CODEOWNERS)
      return 0
      ;;
    .github/*)
      case "$base" in
        *.yml | *.yaml) return 0 ;;
      esac
      ;;
    supply-chain/*)
      case "$base" in
        *.lock) return 0 ;;
      esac
      ;;
    migrations/*)
      case "$base" in
        *.sql) return 0 ;;
      esac
      ;;
  esac
  return 1
}

list=$(mktemp)
trap 'rm -f "$list"' EXIT
git -C "$toplevel" ls-files -z >"$list"

hits=0
while IFS= read -r -d '' path || [[ -n "$path" ]]; do
  [[ -z "$path" ]] && continue
  if ! allowed "$path"; then
    printf 'rust-only: %s\n' "$path"
    hits=1
  fi
done <"$list"

if [[ "$hits" -eq 0 ]]; then
  echo "rust-only: 已跟踪文件都在白名单内。"
  exit 0
fi

if [[ "$exempt" -eq 1 ]]; then
  echo "rust-only: 当前仓库是 burncloud/ci。不合规文件已记录，不阻断。其他仓库会失败。"
  exit 0
fi

echo "rust-only: 存在不在白名单内的已跟踪文件，检查失败。" >&2
exit 1
