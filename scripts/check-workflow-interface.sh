#!/usr/bin/env bash
set -euo pipefail
repo=.
base=
head_rev=
if [[ $# -eq 2 || $# -eq 3 ]]; then
  base=$1
  head_rev=$2
  [[ $# -eq 3 ]] && repo=$3
elif [[ $# -ne 0 ]]; then
  echo "usage: check-workflow-interface.sh [<base> <head> [repo]]" >&2
  exit 2
fi
repo=$(cd "$repo" && pwd)
if [[ -z "$base" || -z "$head_rev" ]]; then
  if [[ -n "${BASE_SHA:-}" && ${BASE_SHA} != null && -n "${HEAD_SHA:-}" && ${HEAD_SHA} != null ]]; then
    base=$BASE_SHA
    head_rev=$HEAD_SHA
  else
    tags=$(git -C "$repo" tag --list 'v*' --sort=-v:refname)
    base=
    while IFS= read -r tag || [[ -n ${tag:-} ]]; do
      [[ -z ${tag:-} ]] && continue
      if [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        base=$tag
        break
      fi
    done <<< "$tags"
    [[ -n $base ]] || { echo "workflow-interface: 没有 vX.Y.Z 标签，无法比较。" >&2; exit 1; }
    head_rev=HEAD
  fi
fi
ensure() {
  git -C "$repo" rev-parse --verify --quiet "${1}^{commit}" >/dev/null && return 0
  git -C "$repo" fetch --no-tags origin "$1"
}
ensure "$base"
ensure "$head_rev"
REPO=$repo BASE_REV=$base HEAD_REV=$head_rev python3 - <<'PY'
import os, subprocess, sys
repo, base_rev, head_rev = os.environ["REPO"], os.environ["BASE_REV"], os.environ["HEAD_REV"]
SCOPES = "actions artifact-metadata attestations checks contents deployments discussions id-token issues models packages pages pull-requests repository-projects security-events statuses".split()
NAMES = {0: "none", 1: "read", 2: "write"}
def git(*args):
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return proc.returncode, proc.stdout
def show(rev, path):
    code, out = git("show", f"{rev}:{path}")
    return None if code else out
def workflows(rev):
    code, out = git("ls-tree", "-r", "--name-only", rev, ".github/workflows")
    if code:
        sys.exit(f"workflow-interface: 无法列出 {rev} 的工作流")
    return [line for line in out.splitlines() if line.endswith((".yml", ".yaml"))]
def version_of(text):
    parts = text.strip().split(".")
    if len(parts) == 3 and all(part.isdigit() and part for part in parts):
        return tuple(int(part) for part in parts)
    return None
def major(rev):
    text = show(rev, "VERSION")
    found = version_of(text.splitlines()[0]) if text and text.splitlines() else None
    if found:
        return found[0]
    name = rev[len("refs/tags/"):] if rev.startswith("refs/tags/") else rev
    found = version_of(name[1:]) if name.startswith("v") else None
    if found:
        return found[0]
    code, out = git("tag", "--points-at", rev)
    best = None
    if code == 0:
        for tag in out.splitlines():
            found = version_of(tag[1:]) if tag.startswith("v") else None
            if found and (best is None or found > best):
                best = found
    return None if best is None else best[0]
def strip_comment(text):
    return (text.split(" #", 1)[0] if " #" in text else text).rstrip()
def split_key(body):
    if ":" not in body or body[:1] in "\"'{[":
        return None
    key, rest = body.split(":", 1)
    key = key.strip()
    if not key or any(ch.isspace() for ch in key):
        return None
    return key, rest.strip()
def plain(rest):
    if len(rest) >= 2 and rest[0] == rest[-1] and rest[0] in "\"'":
        inner = rest[1:-1]
        return inner.replace("''", "'") if rest[0] == "'" else inner.replace('\\"', '"').replace("\\\\", "\\")
    return rest
def is_block(rest):
    return bool(rest) and rest[0] in "|>" and all(char in "+-0123456789" for char in rest[1:])
def canon(rest):
    if rest == "":
        return ("null",)
    if len(rest) >= 2 and rest[0] == rest[-1] and rest[0] in "\"'":
        return ("str", plain(rest))
    low = rest.lower()
    if low in {"true", "yes", "on"}:
        return ("bool", "true")
    if low in {"false", "no", "off"}:
        return ("bool", "false")
    if low in {"null", "~"}:
        return ("null",)
    if rest.isdigit() or (rest[:1] == "-" and rest[1:].isdigit()):
        return ("int", str(int(rest)))
    return ("str", rest)
def shown(value):
    return {"missing": "缺失", "null": "null"}.get(value[0], value[1] if value[0] != "block" else "块:" + value[1])
def empty():
    return {"reusable": False, "root": {}, "root_short": None, "jobs": {}, "inputs": {}, "outputs": set(), "secrets": {}}
def die(path, message):
    sys.exit(f"workflow-interface: {path}: {message}")
def fresh_input():
    return {"required": False, "type": None, "default": ("missing",)}
def fresh_job():
    return {"explicit": False, "short": None, "perms": {}}
def truthy(rest):
    return plain(rest).lower() in {"true", "yes", "on"}
def perm_level(rest, path):
    level = {"none": 0, "read": 1, "write": 2}.get(plain(rest).lower())
    if level is None:
        die(path, f"权限值无法识别: {rest}")
    return level
def parse(text, path):
    doc, lines, stack, index = empty(), text.splitlines(), [], 0
    while index < len(lines):
        raw = lines[index].rstrip("\r")
        if "\t" in raw:
            die(path, "含有制表符")
        if not raw.strip() or raw.lstrip().startswith("#"):
            index += 1
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        content = strip_comment(raw.strip())
        if not content or content in {"---", "..."}:
            index += 1
            continue
        body = content[2:].strip() if content.startswith("- ") else content
        parsed = split_key(body) if body else None
        if parsed is None:
            index += 1
            continue
        key, rest = parsed
        while stack and stack[-1][0] >= indent:
            stack.pop()
        parent = [item[1] for item in stack]
        if is_block(rest):
            block, index = [], index + 1
            while index < len(lines):
                nxt = lines[index].rstrip("\r")
                if "\t" in nxt:
                    die(path, "含有制表符")
                if nxt.strip() and (len(nxt) - len(nxt.lstrip(" "))) <= indent:
                    break
                block.append(nxt.strip())
                index += 1
            if key == "default" and parent[:3] == ["on", "workflow_call", "inputs"] and len(parent) == 4:
                doc["inputs"].setdefault(parent[3], fresh_input())["default"] = ("block", "\n".join(block).strip())
            stack.append((indent, key))
            continue
        if rest.startswith("{") and key in {"inputs", "outputs", "secrets", "permissions"}:
            die(path, f"{key} 用了行内映射")
        if parent == ["on"] and key == "workflow_call":
            doc["reusable"] = True
        elif parent == ["on", "workflow_call", "inputs"]:
            doc["inputs"].setdefault(key, fresh_input())
        elif parent == ["on", "workflow_call", "outputs"]:
            doc["outputs"].add(key)
        elif parent == ["on", "workflow_call", "secrets"]:
            doc["secrets"].setdefault(key, {"required": False})
        elif parent[:3] == ["on", "workflow_call", "inputs"] and len(parent) == 4:
            item = doc["inputs"].setdefault(parent[3], fresh_input())
            if key == "required":
                item["required"] = truthy(rest)
            elif key == "type":
                item["type"] = plain(rest)
            elif key == "default":
                item["default"] = canon(rest)
        elif parent[:3] == ["on", "workflow_call", "secrets"] and len(parent) == 4 and key == "required":
            doc["secrets"].setdefault(parent[3], {"required": False})["required"] = truthy(rest)
        elif not parent and key == "permissions" and rest in {"read-all", "write-all"}:
            doc["root_short"] = rest
        elif parent == ["permissions"]:
            doc["root"][key] = perm_level(rest, path)
        elif parent == ["jobs"]:
            doc["jobs"].setdefault(key, fresh_job())
        elif len(parent) == 2 and parent[0] == "jobs" and key == "permissions":
            job = doc["jobs"].setdefault(parent[1], fresh_job())
            job["explicit"] = True
            if rest in {"read-all", "write-all"}:
                job["short"] = rest
        elif len(parent) == 3 and parent[0] == "jobs" and parent[2] == "permissions":
            job = doc["jobs"].setdefault(parent[1], fresh_job())
            job["explicit"] = True
            job["perms"][key] = perm_level(rest, path)
        stack.append((indent, key))
        index += 1
    return doc
def load(rev, path):
    text = show(rev, path)
    return None if text is None else parse(text, f"{rev}:{path}")
def expand(perms, short, scopes):
    out = {scope: {"read-all": 1, "write-all": 2}.get(short, 0) for scope in scopes} if short else {}
    for scope, level in perms.items():
        out[scope] = max(out.get(scope, 0), level)
    return out
def levels(doc, scopes):
    if doc is None or not doc["reusable"]:
        return {}
    rows = []
    if not doc["jobs"]:
        rows.append(expand(doc["root"], doc["root_short"], scopes))
    for job in doc["jobs"].values():
        rows.append(expand(job["perms"], job["short"], scopes) if job["explicit"] else expand(doc["root"], doc["root_short"], scopes))
    acc = {}
    for row in rows:
        for scope, level in row.items():
            acc[scope] = max(acc.get(scope, 0), level)
    return acc
def effective_default(item):
    if item["default"][0] != "missing":
        return item["default"]
    return {"string": ("str", ""), "boolean": ("bool", "false"), "number": ("int", "0")}.get(item["type"], item["default"])
def compare_map(old_map, new_map, label, breaks, path, required=False, defaults=False):
    for name in sorted(set(old_map) | set(new_map)):
        old, new, where = old_map.get(name), new_map.get(name), f"{path} {name}"
        if new is None:
            breaks.append(f"删除{label} {where}")
            continue
        if old is None:
            if required and new["required"]:
                breaks.append(f"新增必填{label} {where}")
            continue
        if required and not old["required"] and new["required"]:
            breaks.append(f"{label}改为必填 {where}")
        if defaults and effective_default(old) != effective_default(new):
            breaks.append(f"{label}默认值改变 {where}（{shown(effective_default(old))} -> {shown(effective_default(new))}）")
paths = set(workflows(base_rev)) | set(workflows(head_rev))
base_docs = {path: load(base_rev, path) for path in paths}
head_docs = {path: load(head_rev, path) for path in paths}
breaks = []
for path in sorted(paths):
    old, new = base_docs[path], head_docs[path]
    if not ((old and old["reusable"]) or (new and new["reusable"])):
        continue
    old_face = old if old and old["reusable"] else empty()
    new_face = new if new and new["reusable"] else empty()
    compare_map(old_face["inputs"], new_face["inputs"], "输入", breaks, path, True, True)
    compare_map({name: {} for name in old_face["outputs"]}, {name: {} for name in new_face["outputs"]}, "输出", breaks, path)
    compare_map(old_face["secrets"], new_face["secrets"], "secret", breaks, path, True)
scopes = set(SCOPES)
for doc in list(base_docs.values()) + list(head_docs.values()):
    if not doc:
        continue
    scopes.update(doc["root"])
    for job in doc["jobs"].values():
        scopes.update(job["perms"])
def union(docs):
    acc = {}
    for doc in docs.values():
        for scope, level in levels(doc, scopes).items():
            acc[scope] = max(acc.get(scope, 0), level)
    return acc
old_perms, new_perms = union(base_docs), union(head_docs)
for scope in sorted(set(old_perms) | set(new_perms)):
    before, after = old_perms.get(scope, 0), new_perms.get(scope, 0)
    if after > before:
        breaks.append(f"新增权限 {scope}: {NAMES[after]}" if before == 0 else f"权限升高 {scope}: {NAMES[before]} -> {NAMES[after]}")
before_major, after_major = major(base_rev), major(head_rev)
if not breaks:
    print("workflow-interface: 没有破坏性变更。")
elif before_major is not None and after_major is not None and after_major > before_major:
    print(f"workflow-interface: 破坏性变更 {len(breaks)} 项，VERSION 主版本 {before_major} 升到 {after_major}，允许。")
    for item in breaks:
        print(f"workflow-interface: {item}")
else:
    print(f"workflow-interface: 破坏性变更 {len(breaks)} 项，需要提升 VERSION 主版本。", file=sys.stderr)
    for item in breaks:
        print(f"workflow-interface: {item}", file=sys.stderr)
    sys.exit(1)
PY
