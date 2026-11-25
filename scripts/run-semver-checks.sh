#!/usr/bin/env bash
# SEMVER_BASELINE: auto、base、tag，或其他 git rev。
# 基线上没有该 Cargo.toml 时视为新 crate，说明原因后成功退出。
set -euo pipefail

wd=${WORKING_DIRECTORY:-.}
wd=${wd#./}
mode=${SEMVER_BASELINE:-auto}
base_sha=${BASE_SHA:-}

cargo semver-checks --version

if [[ "$mode" == "auto" ]]; then
  if [[ -n "$base_sha" ]]; then
    mode=base
  else
    mode=tag
  fi
fi

rev=""
case "$mode" in
  base)
    if [[ -z "$base_sha" ]]; then
      echo "semver: baseline=base，但当前事件没有 pull request 的 base sha。" >&2
      exit 1
    fi
    rev=$base_sha
    ;;
  tag)
    rev=$(git tag --list 'v*' --sort=-v:refname | head -n 1 || true)
    if [[ -z "$rev" ]]; then
      rev=$(git tag --sort=-creatordate | head -n 1 || true)
    fi
    if [[ -z "$rev" ]]; then
      if [[ "${SEMVER_BASELINE:-auto}" == "auto" ]]; then
        echo "semver: 没有 pull request base，也没有 tag，视为新 crate，跳过。"
        exit 0
      fi
      echo "semver: baseline=tag，但仓库没有任何 tag。" >&2
      exit 1
    fi
    ;;
  *)
    rev=$mode
    ;;
esac

if ! git rev-parse --verify --quiet "${rev}^{commit}" >/dev/null; then
  echo "semver: 无法解析基线 ${rev}。需要完整 git 历史。" >&2
  exit 1
fi

if [[ "$wd" == "." || -z "$wd" ]]; then
  manifest=Cargo.toml
else
  manifest=${wd}/Cargo.toml
fi

if ! git cat-file -e "${rev}:${manifest}" 2>/dev/null; then
  echo "semver: 基线 ${rev} 上不存在 ${manifest}，视为新 crate，跳过。"
  exit 0
fi

args=(--baseline-rev "$rev" --manifest-path "$manifest")
if grep -q '^\[workspace\]' "$manifest"; then
  args+=(--workspace)
fi

echo "semver: 对比 ${rev} (${manifest})"
cargo semver-checks "${args[@]}"
