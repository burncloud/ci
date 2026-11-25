import os
import re
import sys
import unicodedata
from pathlib import Path

SKIP_DIRS = {".git", "target", ".burncloud-ci", "vendor", "mutants.out"}
LICENSE_RE = re.compile(
    r"^//[ \t]*(?:SPDX-License-Identifier[ \t]*:[ \t]*\S.*|Copyright\b.*)$"
)
EXTERNAL_RE = re.compile(r"^// EXTERNAL: https://\S+$")
COMMENT_KINDS = {"line", "block", "outer_doc", "inner_doc"}


class Token:
    __slots__ = ("kind", "start", "end", "text")

    def __init__(self, kind, start, end, text):
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text


def is_xid_start(ch):
    if ch == "_" or ("A" <= ch <= "Z") or ("a" <= ch <= "z"):
        return True
    if ord(ch) < 128:
        return False
    return unicodedata.category(ch) in {"Lu", "Ll", "Lt", "Lm", "Lo", "Nl"}


def is_xid_continue(ch):
    if ch == "_" or ("A" <= ch <= "Z") or ("a" <= ch <= "z") or ("0" <= ch <= "9"):
        return True
    if ord(ch) < 128:
        return False
    return unicodedata.category(ch) in {
        "Lu",
        "Ll",
        "Lt",
        "Lm",
        "Lo",
        "Nl",
        "Mn",
        "Mc",
        "Nd",
        "Pc",
    }


def skip_ident(src, index):
    if index >= len(src) or not is_xid_start(src[index]):
        return index
    index += 1
    while index < len(src) and is_xid_continue(src[index]):
        index += 1
    return index


def skip_suffix(src, index):
    return skip_ident(src, index)


def skip_cooked(src, index, line):
    index += 1
    limit = len(src)
    while index < limit:
        ch = src[index]
        if ch == '"':
            return index + 1, line
        if ch == "\\" and index + 1 < limit and src[index + 1] in {'\\', '"'}:
            index += 2
            continue
        if ch == "\n":
            line += 1
        index += 1
    return limit, line


def skip_raw(src, index, line):
    cursor = index + 1
    hashes = 0
    limit = len(src)
    while cursor < limit and src[cursor] == "#":
        hashes += 1
        cursor += 1
    if cursor >= limit or src[cursor] != '"':
        return None
    cursor += 1
    closer = '"' + ("#" * hashes)
    while cursor < limit:
        if src.startswith(closer, cursor):
            return cursor + len(closer), line
        if src[cursor] == "\n":
            line += 1
        cursor += 1
    return limit, line


def skip_char(src, index, line):
    cursor = index + 1
    limit = len(src)
    if cursor >= limit:
        return limit, line
    if src[cursor] != "\\" and cursor + 1 < limit and src[cursor + 1] == "'":
        return cursor + 2, line
    while cursor < limit:
        ch = src[cursor]
        if ch == "'":
            return cursor + 1, line
        if ch == "\\" and cursor + 1 < limit and src[cursor + 1] != "\n":
            cursor += 2
            continue
        if ch == "/" and cursor + 1 < limit and src[cursor + 1] == "/":
            ahead = cursor
            closed = False
            while ahead < limit and src[ahead] != "\n":
                if src[ahead] == "'":
                    closed = True
                    break
                ahead += 1
            if not closed:
                return cursor, line
        if ch == "\n":
            if cursor + 1 < limit and src[cursor + 1] == "'":
                line += 1
                cursor += 1
                continue
            return cursor, line
        cursor += 1
    return limit, line


def skip_lifetime_or_char(src, index, line):
    cursor = index + 1
    limit = len(src)
    if cursor >= limit:
        return limit, line
    first = src[cursor]
    second = src[cursor + 1] if cursor + 1 < limit else ""
    if second != "'" and (is_xid_start(first) or ("0" <= first <= "9")):
        if first == "r" and second == "#" and cursor + 2 < limit and is_xid_start(src[cursor + 2]):
            return skip_suffix(src, cursor + 3), line
        end = skip_ident(src, cursor)
        if end < limit and src[end] == "'":
            return skip_suffix(src, end + 1), line
        return end, line
    end, line = skip_char(src, index, line)
    return skip_suffix(src, end), line


def tokenize(src):
    tokens = []
    index = 0
    line = 1
    limit = len(src)
    while index < limit:
        ch = src[index]
        if ch == "\n":
            line += 1
            index += 1
            continue
        if ch in " \t\r":
            index += 1
            continue
        if ch == "/" and index + 1 < limit and src[index + 1] == "/":
            third = src[index + 2] if index + 2 < limit else ""
            fourth = src[index + 3] if index + 3 < limit else ""
            if third == "!":
                kind = "inner_doc"
            elif third == "/" and fourth != "/":
                kind = "outer_doc"
            else:
                kind = "line"
            end = index + 2
            while end < limit and src[end] != "\n":
                end += 1
            text = src[index:end]
            if text.endswith("\r"):
                text = text[:-1]
            tokens.append(Token(kind, line, line, text))
            index = end
            continue
        if ch == "/" and index + 1 < limit and src[index + 1] == "*":
            start_line = line
            cursor = index + 2
            depth = 1
            while cursor < limit:
                if src[cursor] == "\n":
                    line += 1
                    cursor += 1
                    continue
                if src[cursor] == "/" and cursor + 1 < limit and src[cursor + 1] == "*":
                    depth += 1
                    cursor += 2
                    continue
                if src[cursor] == "*" and cursor + 1 < limit and src[cursor + 1] == "/":
                    depth -= 1
                    cursor += 2
                    if depth == 0:
                        break
                    continue
                cursor += 1
            tokens.append(Token("block", start_line, line, src[index:cursor]))
            index = cursor
            continue
        if ch == '"':
            index, line = skip_cooked(src, index, line)
            index = skip_suffix(src, index)
            continue
        if ch == "'":
            index, line = skip_lifetime_or_char(src, index, line)
            continue
        if ch in {"b", "c", "r"}:
            nxt = src[index + 1] if index + 1 < limit else ""
            nxt2 = src[index + 2] if index + 2 < limit else ""
            if ch == "r" and nxt == "#" and is_xid_start(nxt2):
                start = index
                index = skip_ident(src, index + 2)
                tokens.append(Token("ident", line, line, src[start:index]))
                continue
            if ch == "r" and nxt in {'"', "#"}:
                found = skip_raw(src, index, line)
                if found is not None:
                    index, line = found
                    index = skip_suffix(src, index)
                    continue
            if ch == "b" and nxt == "'":
                index, line = skip_lifetime_or_char(src, index + 1, line)
                continue
            if ch in {"b", "c"} and nxt == '"':
                index, line = skip_cooked(src, index + 1, line)
                index = skip_suffix(src, index)
                continue
            if ch in {"b", "c"} and nxt == "r" and nxt2 in {'"', "#"}:
                found = skip_raw(src, index + 1, line)
                if found is not None:
                    index, line = found
                    index = skip_suffix(src, index)
                    continue
            end = skip_ident(src, index)
            tokens.append(Token("ident", line, line, src[index:end]))
            index = end
            continue
        if is_xid_start(ch):
            end = skip_ident(src, index)
            tokens.append(Token("ident", line, line, src[index:end]))
            index = end
            continue
        if ch in "#![]{}":
            tokens.append(Token("punct", line, line, ch))
            index += 1
            continue
        index += 1
    return tokens


def is_license(text):
    return LICENSE_RE.match(text) is not None


def is_external(text):
    return EXTERNAL_RE.match(text) is not None


class FileChecker:
    def __init__(self, rel, tokens):
        self.rel = rel
        self.tokens = tokens
        self.errors = []
        self.frames = [{"kind": "file", "preamble": True}]

    def error(self, line, message):
        self.errors.append((self.rel, line, message))

    def prev_solid(self, index):
        cursor = index - 1
        while cursor >= 0 and self.tokens[cursor].kind in COMMENT_KINDS:
            cursor -= 1
        return cursor

    def opens_module(self, brace):
        name_at = self.prev_solid(brace)
        if name_at < 0 or self.tokens[name_at].kind != "ident":
            return False
        mod_at = self.prev_solid(name_at)
        if mod_at < 0:
            return False
        return self.tokens[mod_at].kind == "ident" and self.tokens[mod_at].text == "mod"

    def is_attr(self, index):
        token = self.tokens[index]
        if token.kind != "punct" or token.text != "#":
            return False
        if index + 1 >= len(self.tokens):
            return False
        nxt = self.tokens[index + 1]
        if nxt.kind == "punct" and nxt.text == "[":
            return True
        if nxt.kind == "punct" and nxt.text == "!" and index + 2 < len(self.tokens):
            third = self.tokens[index + 2]
            return third.kind == "punct" and third.text == "["
        return False

    def is_inner_attr(self, index):
        if index + 2 >= len(self.tokens):
            return False
        first, second, third = (
            self.tokens[index],
            self.tokens[index + 1],
            self.tokens[index + 2],
        )
        return (
            first.text == "#"
            and second.text == "!"
            and third.text == "["
        )

    def note_attr_comment(self, token):
        if token.kind == "line" and is_external(token.text):
            return
        self.error(token.start, "不允许的注释")

    def consume_attr(self, index):
        end_line = self.tokens[index].end
        if self.is_inner_attr(index):
            index += 2
        else:
            index += 1
        if index >= len(self.tokens) or self.tokens[index].text != "[":
            return index, end_line
        depth = 0
        while index < len(self.tokens):
            token = self.tokens[index]
            end_line = token.end
            if token.text == "[":
                depth += 1
                index += 1
                continue
            if token.text == "]":
                depth -= 1
                index += 1
                if depth == 0:
                    return index, end_line
                continue
            if token.kind in COMMENT_KINDS:
                self.note_attr_comment(token)
            index += 1
        return index, end_line

    def take_outer_docs(self, index):
        group = [self.tokens[index]]
        prev_end = self.tokens[index].end
        index += 1
        while (
            index < len(self.tokens)
            and self.tokens[index].kind == "outer_doc"
            and self.tokens[index].start <= prev_end + 1
        ):
            group.append(self.tokens[index])
            prev_end = self.tokens[index].end
            index += 1
        while (
            index < len(self.tokens)
            and self.is_attr(index)
            and self.tokens[index].start <= prev_end + 1
        ):
            index, prev_end = self.consume_attr(index)
        if (
            index < len(self.tokens)
            and self.tokens[index].kind == "ident"
            and self.tokens[index].text == "pub"
            and self.tokens[index].start <= prev_end + 1
        ):
            return index
        for token in group:
            self.error(token.start, "文档注释必须紧挨 pub 项")
        return index

    def walk(self):
        index = 0
        total = len(self.tokens)
        while index < total and self.tokens[index].kind == "line" and is_license(self.tokens[index].text):
            index += 1
        while index < total:
            token = self.tokens[index]
            frame = self.frames[-1]
            if token.kind == "inner_doc":
                if not (frame["preamble"] and frame["kind"] in {"file", "mod"}):
                    self.error(token.start, "模块文档必须在文件或模块开头")
                index += 1
                continue
            if token.kind == "outer_doc":
                frame["preamble"] = False
                index = self.take_outer_docs(index)
                continue
            if token.kind == "line" and is_external(token.text):
                index += 1
                continue
            if token.kind in {"line", "block"}:
                self.error(token.start, "不允许的注释")
                frame["preamble"] = False
                index += 1
                continue
            if self.is_attr(index):
                if not self.is_inner_attr(index):
                    frame["preamble"] = False
                index, _end = self.consume_attr(index)
                continue
            if token.text == "{":
                kind = "mod" if self.opens_module(index) else "block"
                self.frames.append({"kind": kind, "preamble": kind == "mod"})
                index += 1
                continue
            if token.text == "}":
                if len(self.frames) > 1:
                    self.frames.pop()
                index += 1
                continue
            frame["preamble"] = False
            index += 1
        return self.errors


def check_source(rel, text):
    if text.startswith("\ufeff"):
        text = text[1:]
    return FileChecker(rel, tokenize(text)).walk()


def rust_files(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [name for name in dirnames if name not in SKIP_DIRS]
        for name in filenames:
            if name.endswith(".rs"):
                found.append(Path(dirpath) / name)
    found.sort()
    return found


def main(argv):
    if len(argv) != 2:
        print("usage: check-comments.py ROOT", file=sys.stderr)
        return 2
    root = Path(argv[1])
    if not root.is_dir():
        print(f"comments: 目录不存在: {root}", file=sys.stderr)
        return 1
    root = root.resolve()
    errors = []
    files = rust_files(root)
    for path in files:
        rel = path.resolve().relative_to(root).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeError:
            errors.append((rel, 1, "不是 UTF-8"))
            continue
        errors.extend(check_source(rel, text))
    if errors:
        errors.sort()
        for rel, line, message in errors:
            print(f"{rel}:{line}: {message}")
        print(f"comments: {len(errors)} 处不允许的注释。", file=sys.stderr)
        return 1
    print(f"comments: 已检查 {len(files)} 个 Rust 文件。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
