#!/usr/bin/env bash
# 有 supply-chain/config.toml 就用调用方的策略。
# 没有目录时：
# - 没有第三方依赖：临时空策略，真跑 cargo vet。
# - 第三方依赖全部来自 github.com/burncloud/<仓库> 的 git 源：写入统一豁免后再跑。
# - 还有其他第三方 crate：失败，并说明要提交 supply-chain/。
set -euo pipefail

# owner 必须正好是 burncloud，仓库名一段且不是 . 或 ..。
# 只允许可选的 .git、?rev=/?tag= 和 #十六进制 sha。
trusted_burncloud_git_source() {
  local source=$1
  local repo
  if [[ ! "$source" =~ ^git\+https://github\.com/burncloud/([A-Za-z0-9_.-]+)(\.git)?(\?(rev|tag)=[A-Za-z0-9._-]+)?(#[0-9a-fA-F]+)?$ ]]; then
    return 1
  fi
  repo=${BASH_REMATCH[1]}
  [[ -n "$repo" && "$repo" != "." && "$repo" != ".." ]]
}

if [[ "${1:-}" == "--classify-source" ]]; then
  if trusted_burncloud_git_source "${2:-}"; then
    exit 0
  fi
  exit 1
fi

write_empty_store() {
  local dest=$1
  cat >"$dest/audits.toml" <<'EOF'

# cargo-vet audits file

[audits]
EOF
  cat >"$dest/config.toml" <<'EOF'

# cargo-vet config file

[cargo-vet]
version = "0.10"
EOF
  printf '%s\n' '' '# cargo-vet imports lock' >"$dest/imports.lock"
}

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

metadata=$(cargo metadata --format-version 1 --locked)
mapfile -t rows < <(printf '%s\n' "$metadata" | jq -r '.packages[] | select(.source != null) | [.name, .version, .source] | @tsv')

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [[ ${#rows[@]} -eq 0 ]]; then
  write_empty_store "$tmp"
  echo "cargo-vet: 调用方没有 supply-chain/，且没有第三方依赖。使用临时空策略运行 cargo vet。"
  cargo vet --locked --store-path "$tmp"
  exit 0
fi

trusted=()
other=()
for row in "${rows[@]}"; do
  name=${row%%$'\t'*}
  rest=${row#*$'\t'}
  version=${rest%%$'\t'*}
  source=${rest#*$'\t'}
  if trusted_burncloud_git_source "$source"; then
    trusted+=("${name}"$'\t'"${version}")
  else
    other+=("${name} ${version} ${source}")
  fi
done

if [[ ${#other[@]} -gt 0 ]]; then
  echo "cargo-vet: 调用方没有 supply-chain/，且存在未由 burncloud/ci 策略覆盖的第三方 crate：" >&2
  printf '  %s\n' "${other[@]}" >&2
  echo "cargo-vet: 只有 github.com/burncloud/<仓库名> 这种 git 源会被自动信任。同名的 crates.io 包不会。" >&2
  echo "cargo-vet: 其余依赖请 cargo vet init，提交 supply-chain/，或 cargo vet import mozilla 后再 certify。" >&2
  exit 1
fi

write_empty_store "$tmp"
{
  echo
  echo "# burncloud/ci 统一策略：信任本组织发布的 crate。"
  for row in "${trusted[@]}"; do
    name=${row%%$'\t'*}
    version=${row#*$'\t'}
    cat >>"$tmp/config.toml" <<EOF

[[exemptions.${name}]]
version = "${version}"
criteria = "safe-to-deploy"
notes = "burncloud/ci 信任 burncloud 组织的 crate"

[[exemptions.${name}]]
version = "${version}"
criteria = "safe-to-run"
notes = "burncloud/ci 信任 burncloud 组织的 crate"
EOF
  done
}
echo "cargo-vet: 没有 supply-chain/。第三方依赖都是 burncloud 组织的 crate，已写入临时信任策略。"
cargo vet --locked --store-path "$tmp"
