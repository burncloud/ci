#!/usr/bin/env bash
# 比较提交的规则集和 GET /rulesets/{id} 的读回结果。
# 关键字段精确相等，避免 jq contains 把改松的规则集当成子集。
# 服务端补上的 id、_links、默认参数只做子集，并且字符串不做子串匹配。
# EXPECTED_ENFORCEMENT 或 --expected-enforcement 覆盖预期 enforcement，默认用提交 JSON 里的值。
set -euo pipefail

expected_enforcement="${EXPECTED_ENFORCEMENT-}"
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-enforcement)
      if [[ $# -lt 2 ]]; then
        echo "缺少 --expected-enforcement 的值。" >&2
        exit 2
      fi
      expected_enforcement=$2
      shift 2
      ;;
    --)
      shift
      positional+=("$@")
      break
      ;;
    -*)
      echo "未知参数: $1" >&2
      exit 2
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

if [[ ${#positional[@]} -ne 2 ]]; then
  echo "用法: check-ruleset-readback.sh [--expected-enforcement 值] <提交的 JSON> <读回的 JSON>" >&2
  exit 2
fi

submitted=${positional[0]}
readback=${positional[1]}
if [[ ! -f "$submitted" ]]; then
  echo "找不到提交的 JSON: ${submitted}" >&2
  exit 2
fi
if [[ ! -f "$readback" ]]; then
  echo "找不到读回的 JSON: ${readback}" >&2
  exit 2
fi

errors=$(
  jq -r --arg expected "$expected_enforcement" -n --slurpfile submitted "$submitted" --slurpfile readback "$readback" '
    def canon_id:
      if . == null then null
      elif type == "number" then .
      elif type == "string" then (tonumber? // .)
      else tostring
      end;

    def actors:
      [(.bypass_actors // [])[]
        | {actor_type, actor_id: (.actor_id | canon_id), bypass_mode}]
      | sort_by(.actor_type, (.actor_id | tostring), .bypass_mode);

    def ref_list(which):
      ((.conditions.ref_name // {})[which] // []) | sort;

    def rule_types:
      [(.rules // [])[].type] | unique | sort;

    def type_dupes:
      [(.rules // []) | group_by(.type)[] | select(length > 1) | .[0].type];

    def status_pairs:
      [(.rules // [])[]
        | select(.type == "required_status_checks")
        | (.parameters.required_status_checks // [])[]
        | {context, integration_id: (.integration_id | canon_id)}]
      | sort_by(.context, (.integration_id | tostring));

    def pull_params:
      ((.rules // []) | map(select(.type == "pull_request")) | .[0].parameters) // {};

    def subset_mismatch($got; $path):
      if type == "object" then
        if $got == null or ($got | type) != "object" then $path
        else
          reduce to_entries[] as $entry (null;
            if . != null then .
            elif ($got | has($entry.key) | not) then
              if $path == "" then $entry.key else $path + "." + $entry.key end
            else
              ($entry.value | subset_mismatch($got[$entry.key];
                if $path == "" then $entry.key else $path + "." + $entry.key end)) as $nested
              | if . != null then . else $nested end
            end
          )
        end
      elif type == "array" then
        if $got == null or ($got | type) != "array" then $path
        else
          . as $items
          | reduce range(0; length) as $index (null;
              if . != null then .
              elif any($got[]; . == $items[$index]) then null
              else $path + "[" + ($index | tostring) + "]"
              end
            )
        end
      elif . == $got then null
      else $path
      end;

    def strip:
      del(.name, .target, .enforcement, .bypass_actors)
      | del(.conditions.ref_name.include, .conditions.ref_name.exclude)
      | .rules = (
          [(.rules // [])[]
            | del(.parameters.required_status_checks)
            | if .type == "pull_request" then del(.parameters) else . end
            | {key: .type, value: del(.type)}
          ] | from_entries
        );

    $submitted[0] as $want
    | $readback[0] as $got
    | (if $expected == "" then $want.enforcement else $expected end) as $want_enforcement
    | [
        (if $want.name == $got.name then empty
         else "name 不一致: 提交 \($want.name | tojson)，读回 \($got.name | tojson)" end),
        (if $want.target == $got.target then empty
         else "target 不一致: 提交 \($want.target | tojson)，读回 \($got.target | tojson)" end),
        (if $want_enforcement == $got.enforcement then empty
         else "enforcement 不一致: 预期 \($want_enforcement | tojson)，读回 \($got.enforcement | tojson)" end),
        (if ($want | actors) == ($got | actors) then empty
         else "bypass_actors 不一致: 提交 \($want | actors | tojson)，读回 \($got | actors | tojson)" end),
        (if ($want | ref_list("include")) == ($got | ref_list("include")) then empty
         else "conditions.ref_name.include 不一致: 提交 \($want | ref_list("include") | tojson)，读回 \($got | ref_list("include") | tojson)" end),
        (if ($want | ref_list("exclude")) == ($got | ref_list("exclude")) then empty
         else "conditions.ref_name.exclude 不一致: 提交 \($want | ref_list("exclude") | tojson)，读回 \($got | ref_list("exclude") | tojson)" end),
        (if ($want | rule_types) == ($got | rule_types) then empty
         else "rules.type 不一致: 提交 \($want | rule_types | tojson)，读回 \($got | rule_types | tojson)" end),
        (if (($want | type_dupes) + ($got | type_dupes) | length) == 0 then empty
         else "rules.type 有重复，无法按类型对齐" end),
        (if ($want | status_pairs) == ($got | status_pairs) then empty
         else "required_status_checks 不一致: 提交 \($want | status_pairs | tojson)，读回 \($got | status_pairs | tojson)" end),
        (
          ($want | pull_params) as $want_pull
          | ($got | pull_params) as $got_pull
          | $want_pull | to_entries[]
          | .key as $key
          | if ($got_pull[$key] == .value) then empty
            else "pull_request.\($key) 不一致: 提交 \(.value | tojson)，读回 \($got_pull[$key] | tojson)"
            end
        ),
        (
          ($want | strip) as $want_rest
          | ($got | strip) as $got_rest
          | ($want_rest | subset_mismatch($got_rest; "")) as $path
          | if $path == null then empty
            else "其余字段不是读回结果的子集: \($path)"
            end
        )
      ] | .[]
  '
) || {
  echo "无法解析规则集 JSON。" >&2
  exit 2
}

if [[ -n "$errors" ]]; then
  printf '%s\n' "$errors" >&2
  exit 1
fi
