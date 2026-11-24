#!/usr/bin/env bash
# 有 supply-chain/config.toml 就用调用方的策略。
# 没有目录时：没有第三方依赖则用临时空策略真跑 cargo vet；有第三方依赖则失败并说明如何初始化。
set -euo pipefail

wd=${1:-.}
cd "$wd"
workspace=${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}

if [[ ! -f Cargo.lock ]]; then
  echo "cargo-vet: 没有 Cargo.lock。请提交锁文件。" >&2
  exit 1
fi

store=""
if [[ -f supply-chain/config.toml ]]; then
  store=$(pwd)/supply-chain
  echo "cargo-vet: 使用 ${store}"
elif [[ -f "$workspace/supply-chain/config.toml" ]]; then
  store=$workspace/supply-chain
  echo "cargo-vet: 使用仓库根的 ${store}"
fi

if [[ -n "$store" ]]; then
  cargo vet --locked --store-path "$store"
  exit 0
fi

count=$(grep -c '^source = ' Cargo.lock || true)
if [[ "$count" -gt 0 ]]; then
  echo "cargo-vet: 调用方没有 supply-chain/，但 Cargo.lock 中有 ${count} 条第三方 source。" >&2
  echo "cargo-vet: 请在 workspace 根目录运行 cargo vet init 并提交 supply-chain/。" >&2
  echo "cargo-vet: 可以用 cargo vet import mozilla 导入已发布审计，再对剩余 crate 执行 cargo vet certify，或在 config.toml 里写下豁免理由。" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/audits.toml" <<'EOF'

# cargo-vet audits file

[audits]
EOF
cat >"$tmp/config.toml" <<'EOF'

# cargo-vet config file

[cargo-vet]
version = "0.10"
EOF
printf '%s\n' '' '# cargo-vet imports lock' >"$tmp/imports.lock"
echo "cargo-vet: 调用方没有 supply-chain/，且没有第三方依赖。使用临时空策略运行 cargo vet。"
cargo vet --locked --store-path "$tmp"
