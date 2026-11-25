#!/usr/bin/env bash
# 确认每个 lib/bin 根文件含有 #![forbid(unsafe_code)]，并拒绝源码里的 unsafe 整词。
# unsafe_code 这个标识符不含独立的 unsafe 单词，因此属性本身不会被第二次检查误伤。
set -euo pipefail

wd="${1:-.}"
wd=$(cd "$wd" && pwd)
manifest="$wd/Cargo.toml"

if [[ ! -f "$manifest" ]]; then
  echo "unsafe: ${wd} 下没有 Cargo.toml。" >&2
  exit 1
fi

metadata=$(cargo metadata --no-deps --format-version 1 --manifest-path "$manifest")
mapfile -t roots < <(printf '%s\n' "$metadata" | jq -r '.packages[].targets[] | select(any(.kind[]; . == "lib" or . == "bin")) | .src_path')

if [[ ${#roots[@]} -eq 0 ]]; then
  echo "unsafe: 没有找到 lib 或 bin 的 crate 根。" >&2
  exit 1
fi

missing=0
for root in "${roots[@]}"; do
  if [[ ! -f "$root" ]]; then
    echo "unsafe: crate 根不存在: ${root}" >&2
    missing=1
    continue
  fi
  if ! grep -Eq '^[[:space:]]*#!\[forbid\(unsafe_code\)\][[:space:]]*$' "$root"; then
    echo "unsafe: ${root} 缺少 #![forbid(unsafe_code)]。" >&2
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

python3 - "$wd" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
allow_paths = []
for candidate in (root / "unsafe-allow.txt",):
    if candidate.is_file():
        allow_paths.append(candidate)
workspace = pathlib.Path(
    __import__("os").environ.get("GITHUB_WORKSPACE", "")
).resolve() if __import__("os").environ.get("GITHUB_WORKSPACE") else None
if workspace is not None:
    repo_allow = workspace / "unsafe-allow.txt"
    if repo_allow.is_file() and repo_allow not in allow_paths:
        allow_paths.append(repo_allow)

allowed_files = set()
allowed_lines = set()
for allow_file in allow_paths:
    base = allow_file.parent
    for raw in allow_file.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if ":" in line:
            path_text, line_no = line.rsplit(":", 1)
            if line_no.isdigit():
                allowed_lines.add((str((base / path_text).resolve()), int(line_no)))
                continue
        allowed_files.add(str((base / line).resolve()))

def blank_comments_and_strings(src: str) -> str:
    out = []
    i = 0
    n = len(src)
    while i < n:
        if src.startswith("/*", i):
            end = src.find("*/", i + 2)
            chunk = src[i:] if end < 0 else src[i : end + 2]
            out.append(re.sub(r"[^\n]", " ", chunk))
            i = n if end < 0 else end + 2
            continue
        if src.startswith("//", i):
            end = src.find("\n", i)
            if end < 0:
                out.append(" " * (n - i))
                break
            out.append(" " * (end - i))
            i = end
            continue
        if src[i] in {'"', "'"} or src.startswith('r#"', i) or src.startswith("r#'", i) or (
            src[i] == "r" and i + 1 < n and src[i + 1] in {'"', "'"}
        ):
            # 粗略抹掉字符串，保留换行，避免注释和字面量里的 unsafe 被当成代码。
            quote = src[i]
            hashes = 0
            if src[i] == "r":
                j = i + 1
                while j < n and src[j] == "#":
                    hashes += 1
                    j += 1
                if j >= n or src[j] not in {'"', "'"}:
                    out.append(src[i])
                    i += 1
                    continue
                quote = src[j]
                start = i
                i = j + 1
                closer = quote + ("#" * hashes)
                end = src.find(closer, i)
                chunk = src[start:] if end < 0 else src[start : end + len(closer)]
                out.append(re.sub(r"[^\n]", " ", chunk))
                i = n if end < 0 else end + len(closer)
                continue
            start = i
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "\n" and quote == "'":
                    break
                if src[i] == quote:
                    i += 1
                    break
                i += 1
            out.append(re.sub(r"[^\n]", " ", src[start:i]))
            continue
        out.append(src[i])
        i += 1
    return "".join(out)

hits = []
for path in root.rglob("*.rs"):
    if any(part in {"target", ".git"} for part in path.parts):
        continue
    resolved = str(path.resolve())
    if resolved in allowed_files:
        continue
    stripped = blank_comments_and_strings(path.read_text(encoding="utf-8"))
    for number, line in enumerate(stripped.splitlines(), start=1):
        if (resolved, number) in allowed_lines:
            continue
        if re.search(r"\bunsafe\b", line):
            original = path.read_text(encoding="utf-8").splitlines()[number - 1]
            hits.append(f"{path}:{number}:{original}")

if hits:
    print("\n".join(hits), file=sys.stderr)
    print("unsafe: 上面的代码行含有 unsafe 关键字。注释、字符串和 unsafe-allow.txt 已排除。", file=sys.stderr)
    sys.exit(1)
PY

echo "unsafe: 已检查 ${#roots[@]} 个 crate 根，源码中没有 unsafe 关键字。"
