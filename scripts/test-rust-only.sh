#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
check=$root/scripts/check-rust-only.sh

new_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q -b main
  printf '%s\n' "$dir"
}

track() {
  local dir=$1
  local path=$2
  local parent
  parent=$(dirname -- "$path")
  mkdir -p -- "${dir}/${parent}"
  printf 'x\n' >"${dir}/${path}"
  git -C "$dir" add -- "$path"
}

expect_ok() {
  local name=$1
  local dir=$2
  local out
  local status=0
  out=$(bash "$check" "$dir" 2>&1) || status=$?
  if [[ "$status" -ne 0 ]]; then
    echo "FAIL ${name}: 应当通过，实际 exit ${status}" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! grep -F -x -e 'rust-only: 已跟踪文件都在白名单内。' >/dev/null <<<"$out"; then
    echo "FAIL ${name}: 缺少通过说明" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  echo "PASS ${name}"
}

expect_fail() {
  local name=$1
  local dir=$2
  shift 2
  local status=0
  local out
  local needle
  out=$(bash "$check" "$dir" 2>&1) || status=$?
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL ${name}: 应当失败" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  for needle in "$@"; do
    if ! grep -F -x -e "rust-only: ${needle}" >/dev/null <<<"$out"; then
      echo "FAIL ${name}: 输出没有 ${needle}" >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
  done
  echo "PASS ${name}"
}

pure=$(new_repo)
track "$pure" src/lib.rs
track "$pure" crates/util/src/lib.rs
track "$pure" Cargo.toml
track "$pure" Cargo.lock
track "$pure" crates/util/Cargo.toml
track "$pure" rust-toolchain
track "$pure" rust-toolchain.toml
track "$pure" deny.toml
track "$pure" clippy.toml
track "$pure" rustfmt.toml
track "$pure" supply-chain/audits.toml
track "$pure" supply-chain/config.toml
track "$pure" supply-chain/imports.lock
track "$pure" supply-chain/nested/extra.lock
track "$pure" README.md
track "$pure" docs/guide.md
track "$pure" .github/workflows/ci.yml
track "$pure" .github/actionlint.yaml
track "$pure" .github/CODEOWNERS
track "$pure" migrations/001_init.sql
track "$pure" migrations/nested/002.sql
track "$pure" .gitignore
track "$pure" crates/util/.gitignore
track "$pure" LICENSE
track "$pure" LICENSE-APACHE
track "$pure" LICENSE-MIT
expect_ok pure "$pure"

migrations_only=$(new_repo)
track "$migrations_only" migrations/001_init.sql
track "$migrations_only" src/lib.rs
expect_ok migrations-sql "$migrations_only"

outside=$(new_repo)
track "$outside" src/lib.rs
track "$outside" migrations/001_init.sql
track "$outside" schema.sql
status=0
out=$(bash "$check" "$outside" 2>&1) || status=$?
if [[ "$status" -eq 0 ]]; then
  echo "FAIL sql-outside: 应当失败" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! grep -F -x -e 'rust-only: schema.sql' >/dev/null <<<"$out"; then
  echo "FAIL sql-outside: 输出没有 schema.sql" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if grep -F -x -e 'rust-only: migrations/001_init.sql' >/dev/null <<<"$out"; then
  echo "FAIL sql-outside: migrations 内的 sql 不应报出" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
echo "PASS sql-outside"

scripts_dir=$(new_repo)
track "$scripts_dir" src/lib.rs
track "$scripts_dir" Cargo.toml
track "$scripts_dir" tools/gen.py
track "$scripts_dir" scripts/run.sh
expect_fail py-sh "$scripts_dir" tools/gen.py scripts/run.sh

lock_outside=$(new_repo)
track "$lock_outside" src/lib.rs
track "$lock_outside" Cargo.lock
track "$lock_outside" supply-chain/imports.lock
track "$lock_outside" deps.lock
expect_fail lock-outside "$lock_outside" deps.lock

github_other=$(new_repo)
track "$github_other" src/lib.rs
track "$github_other" .github/workflows/ci.yml
track "$github_other" .github/CODEOWNERS
track "$github_other" .github/notes.txt
expect_fail github-other "$github_other" .github/notes.txt

status=0
out=$(bash "$check" --exempt "$scripts_dir" 2>&1) || status=$?
if [[ "$status" -ne 0 ]]; then
  echo "FAIL exempt: 应当通过，实际 exit ${status}" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! grep -F -x -e 'rust-only: tools/gen.py' >/dev/null <<<"$out"; then
  echo "FAIL exempt: 没有记录 tools/gen.py" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! grep -F -x -e 'rust-only: scripts/run.sh' >/dev/null <<<"$out"; then
  echo "FAIL exempt: 没有记录 scripts/run.sh" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! grep -F -x -e 'rust-only: 当前仓库是 burncloud/ci。不合规文件已记录，不阻断。其他仓库会失败。' >/dev/null <<<"$out"; then
  echo "FAIL exempt: 缺少豁免说明" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
echo "PASS exempt"
