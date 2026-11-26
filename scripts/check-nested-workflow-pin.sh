#!/usr/bin/env bash
set -euo pipefail

repo=${1:-.}
repo=$(cd "$repo" && pwd)
rust=$repo/.github/workflows/rust.yml
if [[ ! -f "$rust" ]]; then
  echo "nested-pin: 没有 ${rust}" >&2
  exit 1
fi

names=(lint test supply-chain api protect)
declare -A ref_of=()

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^[[:space:]]*uses:[[:space:]]*burncloud/ci/\.github/workflows/([A-Za-z0-9._-]+)\.yml@([^[:space:]#]+) ]]; then
    name="${BASH_REMATCH[1]}"
    ref="${BASH_REMATCH[2]}"
    if [[ -n "${ref_of[$name]+x}" ]]; then
      echo "nested-pin: ${name} 出现了多次" >&2
      exit 1
    fi
    ref_of[$name]=$ref
  fi
done <"$rust"

first=""
for name in "${names[@]}"; do
  if [[ -z "${ref_of[$name]+x}" ]]; then
    echo "nested-pin: rust.yml 没有 ${name} 的 pin" >&2
    exit 1
  fi
  ref=${ref_of[$name]}
  if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    echo "nested-pin: ${name} 的 sha 不是 40 位小写十六进制: ${ref}" >&2
    exit 1
  fi
  if [[ -z "$first" ]]; then
    first=$ref
  elif [[ "$ref" != "$first" ]]; then
    echo "nested-pin: sha 不一致: ${name} 是 ${ref}，其他是 ${first}" >&2
    exit 1
  fi
done

sha=$first
if ! git -C "$repo" merge-base --is-ancestor "$sha" HEAD; then
  echo "nested-pin: ${sha} 不是 HEAD 的祖先" >&2
  exit 1
fi

for name in "${names[@]}"; do
  path=".github/workflows/${name}.yml"
  current=$(git -C "$repo" hash-object "$repo/$path")
  pinned=$(git -C "$repo" rev-parse "${sha}:${path}")
  if [[ "$current" != "$pinned" ]]; then
    echo "nested-pin: ${path} 与 ${sha} 的内容不一致" >&2
    exit 1
  fi
done

echo "nested-pin: ${sha}"
