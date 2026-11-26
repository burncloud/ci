#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script=${root}/scripts/run-semver-checks.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bin=${tmp}/bin
mkdir -p "$bin"
log=${tmp}/shim.log
out=${tmp}/out.txt
cat >"${bin}/cargo-semver-checks" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${SEMVER_SHIM_LOG:?}"
if [[ "${1:-}" == "--version" || "${2:-}" == "--version" ]]; then
  printf '%s\n' "cargo-semver-checks 0.51.0"
  exit 0
fi
prev=""
pkg=""
for arg in "$@"; do
  if [[ "$prev" == "--package" ]]; then
    pkg=$arg
  fi
  prev=$arg
done
if [[ -n "${SEMVER_SHIM_FAIL:-}" && "$pkg" == "$SEMVER_SHIM_FAIL" ]]; then
  printf '%s\n' "shim: 模拟失败 ${pkg}" >&2
  exit 101
fi
exit 0
EOF
chmod 755 "${bin}/cargo-semver-checks"

write_lib() {
  local dir=$1
  local name=$2
  mkdir -p "${dir}/src"
  printf '%s\n' "[package]" "name = \"${name}\"" 'version = "0.1.0"' 'edition = "2021"' 'publish = false' >"${dir}/Cargo.toml"
  printf '%s\n' 'pub fn value() -> i32 { 1 }' >"${dir}/src/lib.rs"
}

write_bin() {
  local dir=$1
  local name=$2
  mkdir -p "${dir}/src"
  printf '%s\n' "[package]" "name = \"${name}\"" 'version = "0.1.0"' 'edition = "2021"' 'publish = false' >"${dir}/Cargo.toml"
  printf '%s\n' 'fn main() {}' >"${dir}/src/main.rs"
}

write_workspace() {
  local dest=$1
  shift
  {
    printf '%s\n' '[workspace]' 'resolver = "2"' 'members = ['
    local member
    for member in "$@"; do
      printf '  "%s",\n' "$member"
    done
    printf '%s\n' ']'
  } >"$dest"
}

init_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" config user.email semver-test@example.com
  git -C "$dir" config user.name semver-test
}

snap() {
  local dir=$1
  local message=$2
  git -C "$dir" add -A
  git -C "$dir" -c commit.gpgsign=false commit -q -m "$message"
  git -C "$dir" rev-parse HEAD
}

run_at() {
  local dir=$1
  local rev=$2
  local fail_pkg=$3
  : >"$log"
  status=0
  (
    cd "$dir"
    PATH="${bin}:${PATH}" \
      SEMVER_SHIM_LOG="$log" \
      SEMVER_SHIM_FAIL="$fail_pkg" \
      WORKING_DIRECTORY=. \
      SEMVER_BASELINE="$rev" \
      BASE_SHA='' \
      bash "$script"
  ) >"$out" 2>&1 || status=$?
}

fail() {
  printf '%s\n' "$*" >&2
  printf '%s\n' "--- output ---" >&2
  cat "$out" >&2
  printf '%s\n' "--- shim ---" >&2
  cat "$log" >&2
  exit 1
}

expect_status() {
  local name=$1
  local want=$2
  if [[ "$status" -ne "$want" ]]; then
    fail "FAIL ${name}: 预期 exit ${want}，实际 exit ${status}"
  fi
}

expect_line() {
  local name=$1
  local text=$2
  if ! grep -Fxq -- "$text" "$out"; then
    fail "FAIL ${name}: 输出没有 ${text}"
  fi
}

expect_absent() {
  local name=$1
  local text=$2
  if grep -F -e "$text" "$out" >/dev/null; then
    fail "FAIL ${name}: 输出不应包含 ${text}"
  fi
}

expect_invoked() {
  local name=$1
  local rev=$2
  local pkg=$3
  local line="semver-checks --baseline-rev ${rev} --manifest-path Cargo.toml --package ${pkg}"
  if ! grep -Fxq -- "$line" "$log"; then
    fail "FAIL ${name}: 没有用 --package ${pkg} 对比"
  fi
}

expect_not_invoked() {
  local name=$1
  local pkg=$2
  if grep -F -e "--package ${pkg}" "$log" >/dev/null; then
    fail "FAIL ${name}: 不应调用 --package ${pkg}"
  fi
}

both=${tmp}/both
init_repo "$both"
write_workspace "$both/Cargo.toml" crates/kept
write_lib "$both/crates/kept" kept
both_rev=$(snap "$both" baseline)
run_at "$both" "$both_rev" ""
expect_status both 0
expect_line both "semver: 基线库包: kept "
expect_line both "semver: 当前库包: kept "
expect_line both "semver: --package kept"
expect_invoked both "$both_rev" kept
expect_absent both "新增包，无基线"
expect_absent both "破坏性改动"
printf '%s\n' "PASS both exit ${status}"

added=${tmp}/added
init_repo "$added"
write_workspace "$added/Cargo.toml" crates/kept
write_lib "$added/crates/kept" kept
added_base=$(snap "$added" baseline)
write_workspace "$added/Cargo.toml" crates/kept crates/fresh
write_lib "$added/crates/fresh" fresh
snap "$added" current >/dev/null
run_at "$added" "$added_base" ""
expect_status added 0
expect_line added "新增包，无基线: fresh"
expect_line added "semver: --package kept"
expect_invoked added "$added_base" kept
expect_not_invoked added fresh
expect_absent added "破坏性改动"
printf '%s\n' "PASS added exit ${status}"

removed=${tmp}/removed
init_repo "$removed"
write_workspace "$removed/Cargo.toml" crates/kept crates/gone crates/tool
write_lib "$removed/crates/kept" kept
write_lib "$removed/crates/gone" gone
write_bin "$removed/crates/tool" tool
removed_base=$(snap "$removed" baseline)
rm -rf "$removed/crates/gone" "$removed/crates/tool"
write_workspace "$removed/Cargo.toml" crates/kept
snap "$removed" current >/dev/null
run_at "$removed" "$removed_base" ""
expect_status removed 1
expect_line removed "semver: 基线库包: gone kept "
expect_line removed "semver: 当前库包: kept "
expect_line removed "semver: 包 gone 在基线存在、当前不存在，算破坏性改动。"
expect_absent removed "包 tool "
expect_absent removed "新增包，无基线"
expect_invoked removed "$removed_base" kept
expect_not_invoked removed gone
expect_not_invoked removed tool
printf '%s\n' "PASS removed exit ${status}"

other=${tmp}/other
init_repo "$other"
write_workspace "$other/Cargo.toml" crates/kept
write_lib "$other/crates/kept" kept
other_rev=$(snap "$other" baseline)
run_at "$other" "$other_rev" kept
expect_status other 101
expect_line other "shim: 模拟失败 kept"
expect_absent other "新增包，无基线"
expect_absent other "破坏性改动"
expect_invoked other "$other_rev" kept
printf '%s\n' "PASS other exit ${status}"

mixed=${tmp}/mixed
init_repo "$mixed"
write_workspace "$mixed/Cargo.toml" crates/oldlib
write_lib "$mixed/crates/oldlib" oldlib
mixed_base=$(snap "$mixed" baseline)
rm -rf "$mixed/crates/oldlib"
write_workspace "$mixed/Cargo.toml" crates/newlib
write_lib "$mixed/crates/newlib" newlib
snap "$mixed" current >/dev/null
run_at "$mixed" "$mixed_base" ""
expect_status mixed 1
expect_line mixed "新增包，无基线: newlib"
expect_line mixed "semver: 包 oldlib 在基线存在、当前不存在，算破坏性改动。"
expect_not_invoked mixed oldlib
expect_not_invoked mixed newlib
if grep -F -e '--package ' "$log" >/dev/null; then
  fail "FAIL mixed: 没有两边都有的库包，不应调用 --package"
fi
printf '%s\n' "PASS mixed exit ${status}"

template=${tmp}/template
init_repo "$template"
write_workspace "$template/Cargo.toml" crates/kept crates/burncloud-template
write_lib "$template/crates/kept" kept
write_lib "$template/crates/burncloud-template" burncloud-template
template_base=$(snap "$template" baseline)
rm -rf "$template/crates/burncloud-template"
write_workspace "$template/Cargo.toml" crates/kept
snap "$template" current >/dev/null
run_at "$template" "$template_base" ""
expect_status template 0
expect_line template "模板占位包已移除: burncloud-template"
expect_absent template "破坏性改动"
expect_invoked template "$template_base" kept
expect_not_invoked template burncloud-template
printf '%s\n' "PASS template exit ${status}"

lookalike=${tmp}/lookalike
init_repo "$lookalike"
write_workspace "$lookalike/Cargo.toml" crates/kept crates/burncloud-template-x crates/burncloud_template
write_lib "$lookalike/crates/kept" kept
write_lib "$lookalike/crates/burncloud-template-x" burncloud-template-x
write_lib "$lookalike/crates/burncloud_template" burncloud_template
lookalike_base=$(snap "$lookalike" baseline)
rm -rf "$lookalike/crates/burncloud-template-x" "$lookalike/crates/burncloud_template"
write_workspace "$lookalike/Cargo.toml" crates/kept
snap "$lookalike" current >/dev/null
run_at "$lookalike" "$lookalike_base" ""
expect_status lookalike 1
expect_line lookalike "semver: 包 burncloud-template-x 在基线存在、当前不存在，算破坏性改动。"
expect_line lookalike "semver: 包 burncloud_template 在基线存在、当前不存在，算破坏性改动。"
expect_absent lookalike "模板占位包已移除"
expect_invoked lookalike "$lookalike_base" kept
expect_not_invoked lookalike burncloud-template-x
expect_not_invoked lookalike burncloud_template
printf '%s\n' "PASS lookalike exit ${status}"
