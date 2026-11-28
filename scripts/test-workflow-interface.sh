#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
check=$root/scripts/check-workflow-interface.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tool=$'      tool:\n        required: false\n        type: string\n        default: ""\n'
optional="${tool}"$'      extra:\n        required: false\n        type: string\n        default: ""\n'
required="${tool}"$'      need:\n        required: true\n        type: string\n'
made=$'      tool:\n        required: true\n        type: string\n        default: ""\n'
changed=$'      tool:\n        required: false\n        type: string\n        default: "x"\n'
root_read=$'  contents: read\n'
root_more=$'  contents: read\n  pull-requests: read\n'
job_more=$'      contents: read\n      pull-requests: read\n'
init_repo() {
  git init -q -b main "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
}
write_repo() {
  local dir=$1 inputs=$2 root_perms=$3 job_perms=$4 version=$5 job_block=
  mkdir -p "$dir/.github/workflows"
  printf '%s\n' "$version" >"$dir/VERSION"
  if [[ -n "$job_perms" ]]; then
    job_block=$(printf '    permissions:\n%s' "$job_perms")
  fi
  cat >"$dir/.github/workflows/rust.yml" <<EOF
name: Rust
on:
  workflow_call:
    inputs:
${inputs}permissions:
${root_perms}jobs:
  build:
${job_block}
    runs-on: ubuntu-24.04
    steps:
      - run: "true"
EOF
}
snap() {
  git -C "$1" add -A
  git -C "$1" -c commit.gpgsign=false commit -q --allow-empty -m snap
  git -C "$1" rev-parse HEAD
}
fail() {
  echo "FAIL $1" >&2
  printf '%s\n' "$2" >&2
  exit 1
}
run_case() {
  local name=$1 want=$2 needle=$3 extra=$4 inputs=$5 root_perms=$6 job_perms=$7 version=$8
  local dir=$tmp/$name base head status=0 out
  rm -rf "$dir"
  init_repo "$dir"
  write_repo "$dir" "$tool" "$root_read" "" "1.0.0"
  base=$(snap "$dir")
  write_repo "$dir" "$inputs" "$root_perms" "$job_perms" "$version"
  head=$(snap "$dir")
  out=$(bash "$check" "$base" "$head" "$dir" 2>&1) || status=$?
  [[ "$status" -eq "$want" ]] || fail "${name}: 预期 exit ${want}，实际 exit ${status}" "$out"
  grep -F -e "$needle" >/dev/null <<<"$out" || fail "${name}: 输出没有 ${needle}" "$out"
  [[ -z "$extra" ]] || grep -F -e "$extra" >/dev/null <<<"$out" || fail "${name}: 输出没有 ${extra}" "$out"
  echo "PASS ${name}"
}
run_case same 0 "没有破坏性变更。" "" "$tool" "$root_read" "" "1.0.0"
run_case optional 0 "没有破坏性变更。" "" "$optional" "$root_read" "" "1.0.0"
run_case removed 1 "删除输入 .github/workflows/rust.yml tool" "" "" "$root_read" "" "1.0.0"
run_case removed-major 0 "删除输入 .github/workflows/rust.yml tool" "主版本 1 升到 2" "" "$root_read" "" "2.0.0"
run_case required-new 1 "新增必填输入 .github/workflows/rust.yml need" "" "$required" "$root_read" "" "1.0.0"
run_case required-major 0 "新增必填输入 .github/workflows/rust.yml need" "主版本 1 升到 2" "$required" "$root_read" "" "2.0.0"
run_case made-required 1 "输入改为必填 .github/workflows/rust.yml tool" "" "$made" "$root_read" "" "1.0.0"
run_case made-major 0 "输入改为必填 .github/workflows/rust.yml tool" "主版本 1 升到 2" "$made" "$root_read" "" "2.0.0"
run_case default-changed 1 "输入默认值改变 .github/workflows/rust.yml tool" "" "$changed" "$root_read" "" "1.0.0"
run_case default-major 0 "输入默认值改变 .github/workflows/rust.yml tool" "主版本 1 升到 2" "$changed" "$root_read" "" "2.0.0"
run_case permission 1 "新增权限 pull-requests: read" "" "$tool" "$root_more" "" "1.0.0"
run_case permission-major 0 "新增权限 pull-requests: read" "主版本 1 升到 2" "$tool" "$root_more" "" "2.0.0"
run_case job-permission 1 "新增权限 pull-requests: read" "" "$tool" "$root_read" "$job_more" "1.0.0"
run_case job-permission-major 0 "新增权限 pull-requests: read" "主版本 1 升到 2" "$tool" "$root_read" "$job_more" "2.0.0"
expect_repo() {
  local name=$1 status=0 out
  shift
  out=$("$@") || status=$?
  [[ "$status" -eq 0 ]] || fail "$name" "$out"
  grep -F -e "没有破坏性变更。" >/dev/null <<<"$out" || fail "$name" "$out"
  echo "PASS ${name}"
}
expect_repo repo-head bash "$check" HEAD HEAD "$root"
(cd "$root" && expect_repo repo-tag bash "$check")
ci=$root/.github/workflows/ci.yml
rust=$root/.github/workflows/rust.yml
grep -F -e 'bash scripts/check-workflow-interface.sh' >/dev/null "$ci" || fail "workflow: ci.yml 没有调用检查" ""
grep -F -e 'bash scripts/test-workflow-interface.sh' >/dev/null "$ci" || fail "workflow: ci.yml 没有调用自测" ""
grep -F -e 'check-workflow-interface.sh' >/dev/null "$rust" && fail "workflow: rust.yml 不应运行接口检查" ""
echo "PASS workflow-wiring"
