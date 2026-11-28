#!/usr/bin/env bash
set -euo pipefail

MAX=400

usage() {
  echo "usage: check-pr-size.sh <base> <head> [repo]" >&2
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
  exit 2
fi

base=$1
head=$2
repo=${3:-.}
repo=$(cd "$repo" && pwd)

if ! git -C "$repo" rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
  echo "pr-size: 找不到 base ${base}" >&2
  exit 2
fi
if ! git -C "$repo" rev-parse --verify --quiet "${head}^{commit}" >/dev/null; then
  echo "pr-size: 找不到 head ${head}" >&2
  exit 2
fi

ignored() {
  local path=$1
  local name
  name=$(basename -- "$path")
  if [[ "$name" == "Cargo.lock" ]]; then
    return 0
  fi
  if [[ "$path" == supply-chain || "$path" == supply-chain/* || "$path" == */supply-chain || "$path" == */supply-chain/* ]]; then
    return 0
  fi
  return 1
}

total=0
counted=()
skipped=()
binaries=()

while IFS=$'\t' read -r added deleted path || [[ -n "${path:-}" ]]; do
  [[ -z "${path:-}" ]] && continue
  if ignored "$path"; then
    skipped+=("$path")
    continue
  fi
  if [[ "$added" == "-" || "$deleted" == "-" ]]; then
    binaries+=("$path")
    continue
  fi
  lines=$((added + deleted))
  total=$((total + lines))
  counted+=("${lines}"$'\t'"${added}"$'\t'"${deleted}"$'\t'"${path}")
done < <(git -C "$repo" -c core.quotepath=false -c diff.renames=true diff --numstat "${base}...${head}")

emit() {
  local stream=$1
  local entry path lines added deleted
  if [[ ${#counted[@]} -gt 0 ]]; then
    for entry in "${counted[@]}"; do
      IFS=$'\t' read -r lines added deleted path <<<"$entry"
      echo "pr-size: ${lines} 行  ${path}  (+${added} -${deleted})" >&"$stream"
    done
  fi
  if [[ ${#binaries[@]} -gt 0 ]]; then
    for path in "${binaries[@]}"; do
      echo "pr-size: 二进制，不计入行数  ${path}" >&"$stream"
    done
  fi
  if [[ ${#skipped[@]} -gt 0 ]]; then
    for path in "${skipped[@]}"; do
      echo "pr-size: 已忽略  ${path}" >&"$stream"
    done
  fi
}

if [[ "$total" -gt "$MAX" ]]; then
  echo "pr-size: ${total} 行，超过上限 ${MAX}" >&2
  emit 2
  exit 1
fi

echo "pr-size: ${total} 行（上限 ${MAX}）"
emit 1
exit 0
