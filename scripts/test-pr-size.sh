#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
check=$root/scripts/check-pr-size.sh

cfg=$(mktemp)
trap 'rm -f "$cfg"' EXIT
export GIT_CONFIG_GLOBAL=$cfg
export GIT_CONFIG_NOSYSTEM=1
git config --global diff.renames false

new_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name test
  git -C "$dir" config user.email test@example.com
  printf '%s\n' "$dir"
}

commit() {
  local dir=$1
  local msg=$2
  git -C "$dir" add -A
  GIT_AUTHOR_DATE='2026-01-01T00:00:00' GIT_COMMITTER_DATE='2026-01-01T00:00:00' git -C "$dir" commit -q --allow-empty -m "$msg"
}

write_lines() {
  local file=$1
  local n=$2
  local i
  mkdir -p -- "$(dirname -- "$file")"
  : >"$file"
  for ((i = 1; i <= n; i++)); do
    printf 'line-%s\n' "$i" >>"$file"
  done
}

run_check() {
  local dir=$1
  local base=$2
  local head=$3
  bash "$check" "$base" "$head" "$dir"
}

expect_ok() {
  local name=$1
  local dir=$2
  local base=$3
  local head=$4
  local total=$5
  shift 5
  local status=0
  local out
  out=$(run_check "$dir" "$base" "$head" 2>&1) || status=$?
  if [[ "$status" -ne 0 ]]; then
    echo "FAIL ${name}: 应当通过，实际 exit ${status}" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! grep -F -x -e "pr-size: ${total} 行（上限 400）" >/dev/null <<<"$out"; then
    echo "FAIL ${name}: 缺少通过说明（预期 ${total} 行）" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  local needle
  for needle in "$@"; do
    if ! grep -F -e "$needle" >/dev/null <<<"$out"; then
      echo "FAIL ${name}: 输出没有 ${needle}" >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
  done
  echo "PASS ${name}"
}

expect_fail() {
  local name=$1
  local dir=$2
  local base=$3
  local head=$4
  local total=$5
  shift 5
  local status=0
  local out
  out=$(run_check "$dir" "$base" "$head" 2>&1) || status=$?
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL ${name}: 应当失败" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! grep -F -x -e "pr-size: ${total} 行，超过上限 400" >/dev/null <<<"$out"; then
    echo "FAIL ${name}: 缺少失败说明（预期 ${total} 行）" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  local needle
  for needle in "$@"; do
    if ! grep -F -e "$needle" >/dev/null <<<"$out"; then
      echo "FAIL ${name}: 输出没有 ${needle}" >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
  done
  echo "PASS ${name}"
}

exact=$(new_repo)
write_lines "$exact/README.md" 1
commit "$exact" base
base_exact=$(git -C "$exact" rev-parse HEAD)
write_lines "$exact/src/lib.rs" 400
commit "$exact" add-400
head_exact=$(git -C "$exact" rev-parse HEAD)
expect_ok exact-400 "$exact" "$base_exact" "$head_exact" 400 "pr-size: 400 行  src/lib.rs  (+400 -0)"

over=$(new_repo)
write_lines "$over/README.md" 1
commit "$over" base
base_over=$(git -C "$over" rev-parse HEAD)
write_lines "$over/src/lib.rs" 401
commit "$over" add-401
head_over=$(git -C "$over" rev-parse HEAD)
expect_fail over-401 "$over" "$base_over" "$head_over" 401 "pr-size: 401 行  src/lib.rs  (+401 -0)"

ignored=$(new_repo)
write_lines "$ignored/README.md" 1
commit "$ignored" base
base_ignored=$(git -C "$ignored" rev-parse HEAD)
write_lines "$ignored/src/lib.rs" 400
write_lines "$ignored/Cargo.lock" 80
write_lines "$ignored/crates/foo/Cargo.lock" 90
write_lines "$ignored/supply-chain/audits.toml" 70
write_lines "$ignored/crates/bar/supply-chain/imports.lock" 60
commit "$ignored" add-ignored
head_ignored=$(git -C "$ignored" rev-parse HEAD)
expect_ok ignore-generated "$ignored" "$base_ignored" "$head_ignored" 400 \
  "pr-size: 400 行  src/lib.rs  (+400 -0)" \
  "pr-size: 已忽略  Cargo.lock" \
  "pr-size: 已忽略  crates/foo/Cargo.lock" \
  "pr-size: 已忽略  supply-chain/audits.toml" \
  "pr-size: 已忽略  crates/bar/supply-chain/imports.lock"

binary=$(new_repo)
write_lines "$binary/README.md" 1
commit "$binary" base
base_binary=$(git -C "$binary" rev-parse HEAD)
write_lines "$binary/src/lib.rs" 400
printf 'a\0b\1c' >"$binary/blob.bin"
commit "$binary" add-binary
head_binary=$(git -C "$binary" rev-parse HEAD)
expect_ok binary-uncounted "$binary" "$base_binary" "$head_binary" 400 \
  "pr-size: 400 行  src/lib.rs  (+400 -0)" \
  "pr-size: 二进制，不计入行数  blob.bin"

binary_over=$(new_repo)
write_lines "$binary_over/README.md" 1
commit "$binary_over" base
base_binary_over=$(git -C "$binary_over" rev-parse HEAD)
write_lines "$binary_over/src/lib.rs" 401
printf 'a\0b\1c' >"$binary_over/blob.bin"
commit "$binary_over" add-binary-over
head_binary_over=$(git -C "$binary_over" rev-parse HEAD)
expect_fail binary-over "$binary_over" "$base_binary_over" "$head_binary_over" 401 \
  "pr-size: 401 行  src/lib.rs  (+401 -0)" \
  "pr-size: 二进制，不计入行数  blob.bin"
if grep -E 'pr-size: 40[0-9]+ 行  blob.bin' >/dev/null <<<"$(run_check "$binary_over" "$base_binary_over" "$head_binary_over" 2>&1 || true)"; then
  echo "FAIL binary-over: 二进制不应计入按文件行数" >&2
  exit 1
fi

counted_note=$(new_repo)
write_lines "$counted_note/README.md" 1
commit "$counted_note" base
base_note=$(git -C "$counted_note" rev-parse HEAD)
write_lines "$counted_note/docs/supply-chain-notes.md" 10
commit "$counted_note" add-notes
head_note=$(git -C "$counted_note" rev-parse HEAD)
expect_ok not-supply-chain-dir "$counted_note" "$base_note" "$head_note" 10 \
  "pr-size: 10 行  docs/supply-chain-notes.md  (+10 -0)"

rename_only=$(new_repo)
write_lines "$rename_only/src/old.rs" 100
commit "$rename_only" base
base_rename=$(git -C "$rename_only" rev-parse HEAD)
git -C "$rename_only" mv -- src/old.rs src/new.rs
commit "$rename_only" rename
head_rename=$(git -C "$rename_only" rev-parse HEAD)
expect_ok rename-only "$rename_only" "$base_rename" "$head_rename" 0 \
  "pr-size: 0 行  src/{old.rs => new.rs}  (+0 -0)"

rename_edit=$(new_repo)
write_lines "$rename_edit/src/old.rs" 100
commit "$rename_edit" base
base_edit=$(git -C "$rename_edit" rev-parse HEAD)
git -C "$rename_edit" mv -- src/old.rs src/new.rs
printf 'line-101\nline-102\nline-103\n' >>"$rename_edit/src/new.rs"
commit "$rename_edit" rename-edit
head_edit=$(git -C "$rename_edit" rev-parse HEAD)
expect_ok rename-edit "$rename_edit" "$base_edit" "$head_edit" 3 \
  "pr-size: 3 行  src/{old.rs => new.rs}  (+3 -0)"

deleted=$(new_repo)
write_lines "$deleted/src/gone.rs" 25
commit "$deleted" base
base_del=$(git -C "$deleted" rev-parse HEAD)
rm -- "$deleted/src/gone.rs"
commit "$deleted" delete
head_del=$(git -C "$deleted" rev-parse HEAD)
expect_ok delete-file "$deleted" "$base_del" "$head_del" 25 \
  "pr-size: 25 行  src/gone.rs  (+0 -25)"

if ! awk '
  $0 ~ /^  pr-size:/ { in_job = 1; next }
  in_job && $0 ~ /^  [A-Za-z0-9_-]+:/ { in_job = 0 }
  in_job && $0 ~ /^    if: github.event_name == '\''pull_request'\''$/ { found = 1 }
  END { exit !found }
' "$root/.github/workflows/rust.yml"; then
  echo "FAIL workflow: pr-size 必须只在 pull_request 上运行" >&2
  exit 1
fi
if ! grep -F -e 'bash .burncloud-ci/scripts/check-pr-size.sh' >/dev/null "$root/.github/workflows/rust.yml"; then
  echo "FAIL workflow: rust.yml 没有调用 check-pr-size.sh" >&2
  exit 1
fi
echo "PASS workflow-pull-request-only"
