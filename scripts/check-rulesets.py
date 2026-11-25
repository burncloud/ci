#!/usr/bin/env python3
"""校验 docs/rulesets 里准备导入的 JSON。不调用 GitHub API。"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIR = ROOT / "docs" / "rulesets"

LAYERS = [
    "lint / fmt",
    "lint / clippy",
    "lint / unsafe",
    "test / cargo-test",
    "test / doc-test",
    "test / cargo-doc",
    "test / msrv",
    "test / extra-targets",
    "test / wit",
    "test / proptest",
    "test / fuzz",
    "test / mutants",
    "supply-chain / deny",
    "supply-chain / audit",
    "supply-chain / vet",
    "api / semver",
    "api / capabilities",
    "protect / protected-paths",
]
CRATE_CONTEXTS = [f"rust / {name}" for name in LAYERS]
CI_CONTEXTS = ["lint-workflows", "resolve"]
for prefix in ("", "rust / ", "caller / "):
    CI_CONTEXTS.extend(f"{prefix}{name}" for name in LAYERS)

ADMIN_PR = {
    "actor_id": 5,
    "actor_type": "RepositoryRole",
    "bypass_mode": "pull_request",
}
ADMIN_ALWAYS = {
    "actor_id": 5,
    "actor_type": "RepositoryRole",
    "bypass_mode": "always",
}


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def load(name):
    path = DIR / name
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        fail(f"{path}: {exc}")


def rule(data, type_name):
    found = [item for item in data["rules"] if item.get("type") == type_name]
    if len(found) != 1:
        fail(f"{data['name']}: 需要恰好一条 {type_name} 规则，实际 {len(found)}")
    return found[0]


def check_branch(data, contexts):
    if data["target"] != "branch" or data["enforcement"] != "disabled":
        fail(f"{data['name']}: target 必须是 branch，enforcement 必须是 disabled")
    if data["bypass_actors"] != [ADMIN_PR]:
        fail(f"{data['name']}: bypass 必须是仓库管理员在 pull_request 模式")
    if data["conditions"]["ref_name"]["include"] != ["~DEFAULT_BRANCH"]:
        fail(f"{data['name']}: 必须只匹配默认分支")
    rule(data, "deletion")
    rule(data, "non_fast_forward")
    pull = rule(data, "pull_request")["parameters"]
    for key in (
        "dismiss_stale_reviews_on_push",
        "require_code_owner_review",
        "require_last_push_approval",
        "required_review_thread_resolution",
    ):
        if pull.get(key) is not True:
            fail(f"{data['name']}: pull_request.{key} 必须为 true")
    if pull.get("required_approving_review_count") != 1:
        fail(f"{data['name']}: 批准数必须是 1")
    status = rule(data, "required_status_checks")["parameters"]
    got = [item["context"] for item in status["required_status_checks"]]
    if got != contexts:
        fail(f"{data['name']}: 检查名与实测名单不一致")
    if any(item.get("integration_id") != 15368 for item in status["required_status_checks"]):
        fail(f"{data['name']}: integration_id 必须是 15368")
    if "resolve" in got and any(name.endswith("resolve") and name != "resolve" for name in got):
        fail(f"{data['name']}: 不要把会跳过的 resolve 放进必需检查")


def main():
    check_branch(load("crate-main.json"), CRATE_CONTEXTS)
    check_branch(load("ci-main.json"), CI_CONTEXTS)

    tags = load("ci-tags.json")
    if tags["target"] != "tag" or tags["enforcement"] != "disabled":
        fail("ci-tags: target 必须是 tag，enforcement 必须是 disabled")
    if tags["bypass_actors"] != []:
        fail("ci-tags: 不能有 bypass，否则管理员可以改写或删除标签")
    if tags["conditions"]["ref_name"]["include"] != ["refs/tags/v*"]:
        fail("ci-tags: ref 必须是 refs/tags/v*")
    update = rule(tags, "update")
    if update.get("parameters") != {"update_allows_fetch_and_merge": False}:
        fail("ci-tags: update 必须带 update_allows_fetch_and_merge=false")
    rule(tags, "deletion")
    rule(tags, "non_fast_forward")
    if any(item.get("type") == "creation" for item in tags["rules"]):
        fail("ci-tags: creation 必须单独成一份规则集")

    create = load("ci-tags-create.json")
    if create["target"] != "tag" or create["enforcement"] != "disabled":
        fail("ci-tags-create: target 必须是 tag，enforcement 必须是 disabled")
    if create["bypass_actors"] != [ADMIN_ALWAYS]:
        fail("ci-tags-create: 只有仓库管理员可以 always bypass")
    if create["conditions"]["ref_name"]["include"] != ["refs/tags/v*"]:
        fail("ci-tags-create: ref 必须是 refs/tags/v*")
    if [item["type"] for item in create["rules"]] != ["creation"]:
        fail("ci-tags-create: 只能有 creation 规则")

    for path in DIR.glob("*.json"):
        data = json.loads(path.read_text())
        if data.get("enforcement") == "evaluate":
            fail(f"{path.name}: 不要写 evaluate")
    print("rulesets: ok")


if __name__ == "__main__":
    main()
