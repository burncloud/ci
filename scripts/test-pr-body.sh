#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
check=$root/scripts/check-pr-body.sh
target='修正了哪些旧问题'
ok_line="pr-body: 正文含有 Markdown 标题「${target}」。"
bad_line="pr-body: 正文没有 Markdown 标题「${target}」。"

run_check() {
  PR_BODY=$1 bash "$check"
}

expect_ok() {
  local name=$1
  local body=$2
  local status=0
  local out
  out=$(run_check "$body" 2>&1) || status=$?
  if [[ "$status" -ne 0 ]]; then
    echo "FAIL ${name}: 应当通过，实际 exit ${status}" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! grep -F -x -e "$ok_line" >/dev/null <<<"$out"; then
    echo "FAIL ${name}: 缺少通过说明" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  echo "PASS ${name}"
}

expect_fail() {
  local name=$1
  local body=$2
  local status=0
  local out
  out=$(run_check "$body" 2>&1) || status=$?
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL ${name}: 应当失败" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! grep -F -x -e "$bad_line" >/dev/null <<<"$out"; then
    echo "FAIL ${name}: 缺少失败说明" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  echo "PASS ${name}"
}

expect_ok has-heading $'说明。\n\n## 修正了哪些旧问题\n\n这条规则此前只靠人工检查。\n'
expect_ok level-1 $'# 修正了哪些旧问题\n'
expect_ok level-6 $'###### 修正了哪些旧问题\n'
expect_ok closing-hashes $'## 修正了哪些旧问题 ##\n'
expect_ok indent-3 $'   ## 修正了哪些旧问题\n'
expect_ok after-fence $'```\n## 修正了哪些旧问题\n```\n# 修正了哪些旧问题\n'
expect_ok injection $'## 修正了哪些旧问题\n$(reboot)\n'
expect_ok crlf $'说明。\r\n\r\n## 修正了哪些旧问题\r\n\r\n正文。\r\n'
expect_ok surrounding-ws $'  ##   修正了哪些旧问题   \n'
expect_ok line-edge-ws $'## 修正了哪些旧问题  \n'
expect_ok after-html-comment $'<!-- ## 修正了哪些旧问题 -->\n## 修正了哪些旧问题\n'
expect_ok after-multiline-comment $'<!--\n## 修正了哪些旧问题\n-->\n## 修正了哪些旧问题\n'
expect_ok marker-comments $'<!-- CURSOR_AGENT_PR_BODY_BEGIN -->\n## 修正了哪些旧问题\n<!-- CURSOR_AGENT_PR_BODY_END -->\n'
expect_ok fence-hides-comment $'```\n<!--\n## 修正了哪些旧问题\n-->\n```\n# 修正了哪些旧问题\n'

expect_fail no-heading $'说明。\n\n修正了哪些旧问题\n\n没有写成标题。\n'
expect_fail html-comment $'<!-- ## 修正了哪些旧问题 -->\n'
expect_fail html-multiline $'<!--\n## 修正了哪些旧问题\n-->\n'
expect_fail html-unclosed $'<!--\n## 修正了哪些旧问题\n'
expect_fail comment-hides-fence $'<!--\n```\n## 修正了哪些旧问题\n```\n-->\n'
expect_fail empty ''
expect_fail in-fence $'说明。\n\n```markdown\n## 修正了哪些旧问题\n```\n\n没有标题。\n'
expect_fail in-tilde $'~~~\n# 修正了哪些旧问题\n~~~\n'
expect_fail fence-indent $'   ```\n## 修正了哪些旧问题\n   ```\n'
expect_fail indented-code $'    ## 修正了哪些旧问题\n'
expect_fail extra-text $'## 修正了哪些旧问题。\n'
expect_fail no-space $'##修正了哪些旧问题\n'
expect_fail other-heading $'## 其他问题\n'
expect_fail unclosed-fence $'```\n## 修正了哪些旧问题\n'
expect_fail injection-text $'$(rm -rf /)\n; exit 0\n'

rust=$root/.github/workflows/rust.yml
ci=$root/.github/workflows/ci.yml
if ! awk '
  $0 ~ /^  pr-body:/ { in_job = 1; next }
  in_job && $0 ~ /^  [A-Za-z0-9_-]+:/ { in_job = 0 }
  in_job && $0 ~ /^    if: github.event_name == '\''pull_request'\'' && toJSON\(inputs.check-pr-body\) != '\''false'\''$/ { found = 1 }
  END { exit !found }
' "$rust"; then
  echo "FAIL workflow: pr-body 必须只在 pull_request 上运行，并且显式 false 能关闭" >&2
  exit 1
fi
if awk '
  $0 ~ /^  pr-body:/ { in_job = 1; next }
  in_job && $0 ~ /^  [A-Za-z0-9_-]+:/ { in_job = 0 }
  in_job && index($0, "github.workflow") { found = 1 }
  END { exit found ? 1 : 0 }
' "$rust"; then
  echo "PASS workflow-name-not-used"
else
  echo "FAIL workflow: pr-body 不能再靠 github.workflow 强制运行" >&2
  exit 1
fi
json_of() {
  case "$1" in
    true) printf '%s' true ;;
    false) printf '%s' false ;;
    null) printf '%s' null ;;
  esac
}
loose_equals_false() {
  case "$1" in
    false|null|0|'') return 0 ;;
    *) return 1 ;;
  esac
}
runs_now() {
  local event=$1
  local input=$2
  local workflow=$3
  local json
  json=$(json_of "$input")
  [[ -n "$workflow" && "$event" == pull_request && "$json" != 'false' ]]
}
runs_before() {
  local event=$1
  local input=$2
  local workflow=$3
  [[ "$event" == pull_request ]] || return 1
  if [[ "$input" == true ]]; then
    return 0
  fi
  [[ "$workflow" == Rust ]]
}
if loose_equals_false null && loose_equals_false false && ! loose_equals_false true; then
  echo "PASS loose-null-equals-false"
else
  echo "FAIL loose-null-equals-false: 直接触发的空输入和 false 宽松相等，裸写 != false 会把直接触发跳过" >&2
  exit 1
fi
if runs_before pull_request false Rust && ! runs_before pull_request false CI; then
  echo "PASS reproduce-old-rust-name-cannot-skip"
else
  echo "FAIL reproduce-old-rust-name-cannot-skip: 旧条件 inputs.check-pr-body || github.workflow == Rust 在调用方名为 Rust 且输入为 false 时仍运行，名为 CI 时能跳过" >&2
  exit 1
fi
if ! runs_now pull_request false Rust && ! runs_now pull_request false CI; then
  echo "PASS rust-name-false-skips"
else
  echo "FAIL rust-name-false-skips: 调用方工作流名为 Rust 时 check-pr-body false 必须能跳过" >&2
  exit 1
fi
if runs_now pull_request null Rust && runs_now pull_request true Rust && runs_now pull_request true CI && ! runs_now push null Rust; then
  echo "PASS direct-null-still-runs"
else
  echo "FAIL direct-null-still-runs: 直接触发输入是 null 时检查仍要跑，显式 true 要跑，push 不跑" >&2
  exit 1
fi
if ! grep -F -e 'bash .burncloud-ci/scripts/check-pr-body.sh' >/dev/null "$rust"; then
  echo "FAIL workflow: rust.yml 没有调用 check-pr-body.sh" >&2
  exit 1
fi
dollar='$'
api_needle="gh api \"/repos/${dollar}{REPO}/pulls/${dollar}{PR_NUMBER}\""
if ! grep -F -e "$api_needle" >/dev/null "$rust"; then
  echo "FAIL workflow: 正文必须从 API 实时读取" >&2
  exit 1
fi
if ! grep -F -e 'export PR_BODY' >/dev/null "$rust"; then
  echo "FAIL workflow: 正文必须经 PR_BODY 传入" >&2
  exit 1
fi
if ! grep -F -e "jq -r '.body // empty'" >/dev/null "$rust"; then
  echo "FAIL workflow: 正文必须从 API 响应写入 PR_BODY" >&2
  exit 1
fi
if grep -F -e 'github.event.pull_request.body' >/dev/null "$rust"; then
  echo "FAIL workflow: 不能把事件里的旧正文拼进检查" >&2
  exit 1
fi
if ! awk '
  $0 ~ /^      check-pr-body:/ { in_input = 1; next }
  in_input && $0 ~ /^      [A-Za-z0-9-]+:/ { in_input = 0 }
  in_input && $0 ~ /^        type: boolean$/ { bool = 1 }
  in_input && $0 ~ /^        default: true$/ { found = 1 }
  END { exit !(found && bool) }
' "$rust"; then
  echo "FAIL workflow: check-pr-body 必须是默认 true 的布尔输入" >&2
  exit 1
fi
if ! grep -F -x -e '  pull-requests: read' >/dev/null "$rust"; then
  echo "FAIL workflow: rust.yml 需要 pull-requests: read" >&2
  exit 1
fi
if ! grep -F -x -e '  pull-requests: read' >/dev/null "$ci"; then
  echo "FAIL workflow: ci.yml 需要 pull-requests: read" >&2
  exit 1
fi
echo "PASS workflow-pull-request-only"
