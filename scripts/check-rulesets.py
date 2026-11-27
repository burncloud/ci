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
    "lint / comments",
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
    "rust-only",
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
CURSOR_APP_ID = 1210556
CURSOR_APP_ALWAYS = {
    "actor_id": CURSOR_APP_ID,
    "actor_type": "Integration",
    "bypass_mode": "always",
}
TAG_WRITER_BYPASS = [ADMIN_ALWAYS, CURSOR_APP_ALWAYS]


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


EXPECTED_STAR_OWNERS = {"@rustburn", "@ivories"}


def star_owners(text):
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if parts[0] == "*":
            return set(parts[1:])
    return None


def check_codeowners():
    path = ROOT / ".github" / "CODEOWNERS"
    if not path.is_file():
        fail("缺少 .github/CODEOWNERS")
    owners = star_owners(path.read_text())
    if owners is None:
        fail(".github/CODEOWNERS 必须有覆盖 * 的规则")
    if owners != EXPECTED_STAR_OWNERS:
        fail(".github/CODEOWNERS 的 * 规则必须是 @rustburn 和 @ivories")


def self_test_codeowners():
    if star_owners("* @rustburn @ivories\n") != EXPECTED_STAR_OWNERS:
        fail("CODEOWNERS 自测：真实账号应当通过")
    if star_owners("* @ivories @rustburn\n") != EXPECTED_STAR_OWNERS:
        fail("CODEOWNERS 自测：账号顺序不影响结果")
    placeholder = "@" + "REPLACE" + "-WITH-" + "OWNER"
    other = "@" + "REPLACE" + "-WITH-" + "REVIEWER"
    if star_owners(f"# 注释\n* {placeholder} {other}\n") == EXPECTED_STAR_OWNERS:
        fail("CODEOWNERS 自测：占位账号不应当通过")
    if star_owners("* @rustburn\n") == EXPECTED_STAR_OWNERS:
        fail("CODEOWNERS 自测：缺少 ivories 不应当通过")


def organization_admin_actor_ids_ok(data):
    for actor in data.get("bypass_actors") or []:
        if actor.get("actor_type") != "OrganizationAdmin":
            continue
        if "actor_id" not in actor or actor["actor_id"] is not None:
            return False
    return True


def check_organization_admin(data, name):
    if not organization_admin_actor_ids_ok(data):
        fail(f"{name}: OrganizationAdmin 的 actor_id 必须是 null")


def self_test_organization_admin():
    null_id = {
        "bypass_actors": [
            {
                "actor_id": None,
                "actor_type": "OrganizationAdmin",
                "bypass_mode": "pull_request",
            }
        ]
    }
    numeric_id = {
        "bypass_actors": [
            {
                "actor_id": 1,
                "actor_type": "OrganizationAdmin",
                "bypass_mode": "pull_request",
            }
        ]
    }
    if not organization_admin_actor_ids_ok(null_id):
        fail("OrganizationAdmin 自测：actor_id 为 null 应当通过")
    if organization_admin_actor_ids_ok(numeric_id):
        fail("OrganizationAdmin 自测：actor_id 为数字不应当通过")


def copied(data):
    return json.loads(json.dumps(data))


def rule_types(data):
    return [item.get("type") for item in data["rules"]]


def ref_spec(data):
    return data["conditions"]["ref_name"]


def tag_shell_problem(data):
    if data.get("target") != "tag" or data.get("enforcement") != "disabled":
        return "target 必须是 tag，enforcement 必须是 disabled"
    return None


def vstar_scope_problem(data):
    shell = tag_shell_problem(data)
    if shell:
        return shell
    spec = ref_spec(data)
    if spec.get("include") != ["refs/tags/v*"]:
        return "include 必须只是 refs/tags/v*"
    if spec.get("exclude") != ["refs/tags/latest"]:
        return "exclude 必须显式排除 refs/tags/latest"
    return None


def create_problem(data):
    scope = vstar_scope_problem(data)
    if scope:
        return scope
    if data.get("bypass_actors") != TAG_WRITER_BYPASS:
        return "bypass 必须恰好是仓库管理员和 Cursor app 的 always"
    if rule_types(data) != ["creation"]:
        return "只能有 creation"
    return None


def keep_problem(data):
    scope = vstar_scope_problem(data)
    if scope:
        return scope
    if data.get("bypass_actors") != []:
        return "不能有 bypass，否则管理员可以改写或删除标签"
    if rule_types(data) != ["update", "deletion", "non_fast_forward"]:
        return "规则必须是 update、deletion、non_fast_forward"
    update = [item for item in data["rules"] if item.get("type") == "update"]
    if len(update) != 1 or "parameters" in update[0]:
        return "update 不要带 parameters"
    return None


def latest_scope_problem(data):
    shell = tag_shell_problem(data)
    if shell:
        return shell
    spec = ref_spec(data)
    if spec.get("include") != ["refs/tags/latest"]:
        return "include 必须只是 refs/tags/latest"
    if spec.get("exclude") != []:
        return "exclude 必须为空"
    return None


def latest_delete_problem(data):
    scope = latest_scope_problem(data)
    if scope:
        return scope
    if data.get("bypass_actors") != []:
        return "deletion 不能有 bypass"
    if rule_types(data) != ["deletion"]:
        return "只能有 deletion"
    return None


def latest_move_problem(data):
    scope = latest_scope_problem(data)
    if scope:
        return scope
    if data.get("bypass_actors") != TAG_WRITER_BYPASS:
        return "bypass 必须恰好是仓库管理员和 Cursor app 的 always"
    if rule_types(data) != ["update", "non_fast_forward", "creation"]:
        return "规则必须是 update、non_fast_forward、creation"
    if any(item.get("type") == "deletion" for item in data["rules"]):
        return "deletion 不能和 bypass 放在同一份规则集"
    update = [item for item in data["rules"] if item.get("type") == "update"]
    if len(update) != 1 or "parameters" in update[0]:
        return "update 不要带 parameters"
    return None


def self_test_tags():
    create = load("ci-tags-create.json")
    tags = load("ci-tags.json")
    delete = load("ci-tags-latest-delete.json")
    move = load("ci-tags-latest-move.json")
    if create_problem(create):
        fail("ci-tags-create 自测：期望 JSON 应当通过")
    if keep_problem(tags):
        fail("ci-tags 自测：期望 JSON 应当通过")
    if latest_delete_problem(delete):
        fail("ci-tags-latest-delete 自测：期望 JSON 应当通过")
    if latest_move_problem(move):
        fail("ci-tags-latest-move 自测：期望 JSON 应当通过")
    null_bypass = copied(create)
    null_bypass["bypass_actors"] = None
    if create_problem(null_bypass) is None:
        fail("ci-tags-create 自测：bypass 为 null 应当失败")
    empty_bypass = copied(create)
    empty_bypass["bypass_actors"] = []
    if create_problem(empty_bypass) is None:
        fail("ci-tags-create 自测：空 bypass 应当失败")
    request_bypass = copied(create)
    request_bypass["bypass_actors"] = [ADMIN_PR]
    if create_problem(request_bypass) is None:
        fail("ci-tags-create 自测：pull_request bypass 应当失败")
    open_latest = copied(create)
    open_latest["conditions"]["ref_name"]["exclude"] = []
    if create_problem(open_latest) is None:
        fail("ci-tags-create 自测：没有排除 latest 应当失败")
    wildcard = copied(tags)
    wildcard["conditions"]["ref_name"]["include"] = ["refs/tags/*"]
    if keep_problem(wildcard) is None:
        fail("ci-tags 自测：refs/tags/* 应当失败")
    movable = copied(tags)
    movable["bypass_actors"] = [ADMIN_ALWAYS]
    if keep_problem(movable) is None:
        fail("ci-tags 自测：有 bypass 应当失败")
    deletable = copied(delete)
    deletable["bypass_actors"] = [ADMIN_ALWAYS]
    if latest_delete_problem(deletable) is None:
        fail("ci-tags-latest-delete 自测：有 bypass 应当失败")
    combined = copied(move)
    combined["rules"] = combined["rules"] + [{"type": "deletion"}]
    if latest_move_problem(combined) is None:
        fail("ci-tags-latest-move 自测：deletion 和 bypass 在同一份规则集应当失败")
    stuck = copied(move)
    stuck["rules"] = [item for item in stuck["rules"] if item["type"] != "creation"]
    if latest_move_problem(stuck) is None:
        fail("ci-tags-latest-move 自测：缺少 creation 应当失败")
    admin_only = copied(create)
    admin_only["bypass_actors"] = [ADMIN_ALWAYS]
    if create_problem(admin_only) is None:
        fail("ci-tags-create 自测：缺少 Integration 应当失败")
    wrong_id = copied(move)
    wrong_id["bypass_actors"] = [
        ADMIN_ALWAYS,
        {
            "actor_id": CURSOR_APP_ID + 1,
            "actor_type": "Integration",
            "bypass_mode": "always",
        },
    ]
    if latest_move_problem(wrong_id) is None:
        fail("ci-tags-latest-move 自测：Integration id 错误应当失败")
    pull_mode = copied(create)
    pull_mode["bypass_actors"] = [
        ADMIN_ALWAYS,
        {
            "actor_id": CURSOR_APP_ID,
            "actor_type": "Integration",
            "bypass_mode": "pull_request",
        },
    ]
    if create_problem(pull_mode) is None:
        fail("ci-tags-create 自测：Integration 模式不是 always 应当失败")
    app_on_tags = copied(tags)
    app_on_tags["bypass_actors"] = [CURSOR_APP_ALWAYS]
    if keep_problem(app_on_tags) is None:
        fail("ci-tags 自测：出现 Integration bypass 应当失败")
    app_on_delete = copied(delete)
    app_on_delete["bypass_actors"] = [CURSOR_APP_ALWAYS]
    if latest_delete_problem(app_on_delete) is None:
        fail("ci-tags-latest-delete 自测：出现 Integration bypass 应当失败")


def main():
    self_test_codeowners()
    self_test_organization_admin()
    self_test_tags()
    check_codeowners()
    check_branch(load("crate-main.json"), CRATE_CONTEXTS)
    check_branch(load("ci-main.json"), CI_CONTEXTS)

    for name, check in (
        ("ci-tags.json", keep_problem),
        ("ci-tags-create.json", create_problem),
        ("ci-tags-latest-delete.json", latest_delete_problem),
        ("ci-tags-latest-move.json", latest_move_problem),
    ):
        problem = check(load(name))
        if problem:
            fail(f"{name}: {problem}")

    for path in DIR.glob("*.json"):
        data = json.loads(path.read_text())
        if data.get("enforcement") == "evaluate":
            fail(f"{path.name}: 不要写 evaluate")
        check_organization_admin(data, path.name)
    print("rulesets: ok")


if __name__ == "__main__":
    main()
