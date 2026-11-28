#!/usr/bin/env bash
set -euo pipefail

target='修正了哪些旧问题'
marker_char=
marker_len=0
marker_rest=
heading=

trim_ws() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

strip_indent() {
  local s=$1
  local i=0
  while [[ "$i" -lt 3 && "$s" == ' '* ]]; do
    s=${s# }
    i=$((i + 1))
  done
  printf '%s' "$s"
}

only_ws() {
  [[ -z "${1//[[:space:]]/}" ]]
}

fence_marker() {
  local s=$1
  local ch n rest
  case "$s" in
    '`'*) ch='`' ;;
    '~'*) ch='~' ;;
    *) return 1 ;;
  esac
  n=0
  rest=$s
  while [[ "$rest" == "$ch"* ]]; do
    rest=${rest#"$ch"}
    n=$((n + 1))
  done
  if [[ "$n" -lt 3 ]]; then
    return 1
  fi
  marker_char=$ch
  marker_len=$n
  marker_rest=$rest
  return 0
}

heading_text() {
  local s n rest
  s=$(strip_indent "$1")
  case "$s" in
    ' '*|$'\t'*) return 1 ;;
  esac
  case "$s" in
    '#'*) ;;
    *) return 1 ;;
  esac
  n=0
  rest=$s
  while [[ "$rest" == '#'* ]]; do
    rest=${rest#'#'}
    n=$((n + 1))
    if [[ "$n" -gt 6 ]]; then
      return 1
    fi
  done
  if [[ -n "$rest" && "$rest" != ' '* && "$rest" != $'\t'* ]]; then
    return 1
  fi
  rest=$(trim_ws "$rest")
  if [[ "$rest" =~ ^(.*)[[:space:]]#+$ ]]; then
    rest=$(trim_ws "${BASH_REMATCH[1]}")
  fi
  heading=$rest
  return 0
}

strip_comments() {
  local rest=$1
  local before
  visible=
  while [[ "$rest" == *'<!--'* ]]; do
    before=${rest%%'<!--'*}
    visible+="$before"
    rest=${rest#*'<!--'}
    if [[ "$rest" == *'-->'* ]]; then
      rest=${rest#*'-->'}
    else
      in_comment=1
      return 0
    fi
  done
  visible+="$rest"
}

body=${PR_BODY-}
body=${body//$'\r'/}
in_fence=0
in_comment=0
fence_char=
fence_len=0
visible=

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$in_comment" -eq 1 ]]; then
    if [[ "$line" == *'-->'* ]]; then
      line=${line#*'-->'}
      in_comment=0
    else
      continue
    fi
  fi
  content=$(strip_indent "$line")
  if [[ "$in_fence" -eq 1 ]]; then
    if fence_marker "$content" && [[ "$marker_char" == "$fence_char" && "$marker_len" -ge "$fence_len" ]] && only_ws "$marker_rest"; then
      in_fence=0
    fi
    continue
  fi
  if fence_marker "$content" && [[ "$marker_char" != '`' || "$marker_rest" != *'`'* ]]; then
    in_fence=1
    fence_char=$marker_char
    fence_len=$marker_len
    continue
  fi
  strip_comments "$line"
  if heading_text "$visible" && [[ "$heading" == "$target" ]]; then
    echo "pr-body: 正文含有 Markdown 标题「${target}」。"
    exit 0
  fi
done <<< "$body"

echo "pr-body: 正文没有 Markdown 标题「${target}」。" >&2
exit 1
