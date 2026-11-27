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
track "$pure" .gitignore
track "$pure" crates/util/.gitignore
track "$pure" LICENSE
track "$pure" LICENSE-APACHE
track "$pure" LICENSE-MIT
track "$pure" LICENSE.md
track "$pure" LICENSE.txt
track "$pure" "src/my file.rs"
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

license_py=$(new_repo)
track "$license_py" src/lib.rs
track "$license_py" LICENSE
track "$license_py" LICENSE-MIT
track "$license_py" LICENSE-APACHE
track "$license_py" LICENSE.md
track "$license_py" LICENSE.txt
track "$license_py" LICENSE.py
status=0
out=$(bash "$check" "$license_py" 2>&1) || status=$?
if [[ "$status" -eq 0 ]]; then
  echo "FAIL license-py: 应当失败" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! grep -F -x -e 'rust-only: LICENSE.py' >/dev/null <<<"$out"; then
  echo "FAIL license-py: 输出没有 LICENSE.py" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
for kept in LICENSE LICENSE-MIT LICENSE-APACHE LICENSE.md LICENSE.txt src/lib.rs; do
  if grep -F -x -e "rust-only: ${kept}" >/dev/null <<<"$out"; then
    echo "FAIL license-py: ${kept} 不应报出" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
done
echo "PASS license-py"

space=$(new_repo)
track "$space" "src/my file.rs"
track "$space" "bad name.py"
status=0
out=$(bash "$check" "$space" 2>&1) || status=$?
if [[ "$status" -eq 0 ]]; then
  echo "FAIL space: 应当失败" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! grep -F -x -e 'rust-only: bad name.py' >/dev/null <<<"$out"; then
  echo "FAIL space: 输出没有 bad name.py" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if grep -F -x -e 'rust-only: src/my file.rs' >/dev/null <<<"$out"; then
  echo "FAIL space: src/my file.rs 不应报出" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
echo "PASS space"

gitlink=$(new_repo)
track "$gitlink" src/lib.rs
track "$gitlink" README.md
git -C "$gitlink" update-index --add --cacheinfo 160000,0123456789abcdef0123456789abcdef01234567,vendor.md
status=0
out=$(bash "$check" "$gitlink" 2>&1) || status=$?
if [[ "$status" -eq 0 ]]; then
  echo "FAIL gitlink: 应当失败" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! grep -F -x -e 'rust-only: vendor.md' >/dev/null <<<"$out"; then
  echo "FAIL gitlink: 输出没有 vendor.md" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if grep -F -x -e 'rust-only: README.md' >/dev/null <<<"$out"; then
  echo "FAIL gitlink: README.md 不应报出" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if grep -F -x -e 'rust-only: src/lib.rs' >/dev/null <<<"$out"; then
  echo "FAIL gitlink: src/lib.rs 不应报出" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
echo "PASS gitlink"

crate_sql=$(new_repo)
track "$crate_sql" src/lib.rs
track "$crate_sql" migrations/0001.sql
track "$crate_sql" crates/x/migrations/0001.sql
expect_ok crate-migrations "$crate_sql"

expect_direct_sql_fail() {
  local name=$1
  local bad=$2
  local dir
  dir=$(new_repo)
  track "$dir" src/lib.rs
  track "$dir" migrations/0001.sql
  track "$dir" "$bad"
  local status=0
  local out
  out=$(bash "$check" "$dir" 2>&1) || status=$?
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL ${name}: 应当失败" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! grep -F -x -e "rust-only: ${bad}" >/dev/null <<<"$out"; then
    echo "FAIL ${name}: 输出没有 ${bad}" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if grep -F -x -e 'rust-only: migrations/0001.sql' >/dev/null <<<"$out"; then
    echo "FAIL ${name}: migrations/0001.sql 不应报出" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  echo "PASS ${name}"
}

expect_direct_sql_fail migrations-subdir migrations/sub/0001.sql
expect_direct_sql_fail crate-migrations-subdir crates/x/migrations/sub/0001.sql
expect_direct_sql_fail sql-beside-crate crates/x/0001.sql
expect_direct_sql_fail migrations-name-prefix my-migrations/0001.sql
expect_direct_sql_fail migrations-name-suffix migrations-old/0001.sql

mig_script=$(new_repo)
track "$mig_script" src/lib.rs
track "$mig_script" migrations/0001.sql
track "$mig_script" migrations/tool.py
track "$mig_script" migrations/run.sh
status=0
out=$(bash "$check" "$mig_script" 2>&1) || status=$?
if [[ "$status" -eq 0 ]]; then
  echo "FAIL migrations-script: 应当失败" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! grep -F -x -e 'rust-only: migrations/tool.py' >/dev/null <<<"$out"; then
  echo "FAIL migrations-script: 输出没有 migrations/tool.py" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! grep -F -x -e 'rust-only: migrations/run.sh' >/dev/null <<<"$out"; then
  echo "FAIL migrations-script: 输出没有 migrations/run.sh" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if grep -F -x -e 'rust-only: migrations/0001.sql' >/dev/null <<<"$out"; then
  echo "FAIL migrations-script: migrations/0001.sql 不应报出" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
echo "PASS migrations-script"
