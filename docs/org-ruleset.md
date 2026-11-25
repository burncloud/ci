# 组织规则集（只作建议，不要直接应用）

下面的 JSON 只放在文档里。不要用它调用规则集 API，也不要把它应用到 `burncloud` 组织。`enforcement` 保持 `evaluate`。在打出不可变 tag 或选定 SHA 之前，不要改成 `active`。

## 主方案：required workflow

调用方仓库里的 YAML 挡不住改检查。有人可以在 PR 里把 `protected-paths` 改空、换掉 `uses`，或写一个同名空 job 凑状态检查。只配 `required_status_checks` 也不够：不写 `integration_id` 时，普通 commit status 可以冒充通过。

主方案是规则类型 `workflows`，要求 `burncloud/ci` 里某个不可变 ref 上的 `.github/workflows/rust.yml` 必须通过。`repository_id` 是 `1469670652`。ref 用 `refs/tags/vX.Y.Z` 或 40 位 SHA，不要用会移动的 `v1`。

这条规则直接运行本仓库的 `rust.yml`，不会传入 inputs。`working-directory`、开关和 semver 基线在表达式里用 `||` 落到空值或 `auto`；受保护路径输入为空时，脚本使用自己的默认列表。调用方因此改不了这套默认行为。不要再同时让每个 crate 仓库用 `uses` 跑一遍，否则 CI 会跑两遍。调用方文件可以留着给人读，但安全边界是这条规则。

`rust.yml` 在 `burncloud/ci` 里作为顶层工作流跑过一次（https://github.com/burncloud/ci/actions/runs/45523156265），检查名是两段。组织规则把同一文件注入到别的 crate 仓库时，名字还没有核对，**打 v1 前待验证**：

- `lint / fmt`
- `lint / clippy`
- `lint / unsafe`
- `test / cargo-test`
- `test / doc-test`
- `test / cargo-doc`
- `test / msrv`
- `test / extra-targets`
- `test / wit`
- `test / proptest`
- `test / fuzz`
- `test / mutants`
- `supply-chain / deny`
- `supply-chain / audit`
- `supply-chain / vet`
- `api / semver`
- `api / capabilities`
- `protect / protected-paths`
- `resolve`

这些两段式名字来自 `burncloud/ci` 上把 `rust.yml` 当顶层工作流跑出来的结果。组织规则把同一文件注入到别的 crate 仓库时，名字还没有核对，**打 v1 前待验证**。在那之前，下面的 JSON 不包含 `required_status_checks`，避免名字对不上时所有 PR 被永远卡住。`burncloud/ci` 自己的 `ci.yml` 只跑 `lint-workflows`，不再用 job id `rust` 包一层。

## 多个 working-directory

required workflow 一次只用一个 `working-directory`，默认是仓库根。一个仓库里有多个 crate 时：

- 优先拆成每个 crate 一个仓库，继续用上面的 required workflow。
- 必须放在一起时，不要共用一个叫 `rust` 的 job。每个目录一个 job，检查名会变成 `<job id> / lint / fmt` 这种三段名字。规则集得按这些真实名字逐个填写。一条钉在 `rust.yml` 上的 required workflow 覆盖不了多个目录。

```yaml
jobs:
  foo:
    uses: burncloud/ci/.github/workflows/rust.yml@vX.Y.Z
    with:
      working-directory: crates/foo
  bar:
    uses: burncloud/ci/.github/workflows/rust.yml@vX.Y.Z
    with:
      working-directory: crates/bar
```

## 谁来批准

审批人用哪个账号由仓库所有者决定，这里不指定。如果 PR 作者本身是组织管理员（当前作者 `rustburn` 如果是），`bypass_actors` 里的组织管理员身份可以让他绕过审批。这是规则集 API 的行为，不是额外开的口子。在决定审批账号之前保持 `evaluate`。

`bypass_actors` 保留全体组织管理员，`actor_type` 是 `OrganizationAdmin`，`actor_id` 用 `1`，`bypass_mode` 是 `pull_request`。导入前如果 API 拒绝这个 id，以组织设置页面导出的值为准。`require_last_push_approval` 先保持 false。

## 所有仓库的默认分支

- 禁止删除默认分支，禁止强推。
- 必须走 pull request，从而禁止直接推送。
- 至少一个来自非作者主体的批准。新提交使旧批准失效。
- 只允许 squash 和 rebase，并要求线性历史。
- required workflow 如上。在外部仓库核对出真实检查名之前，不配 `required_status_checks`。
- 分支必须包含最新的默认分支。

## `burncloud/ci`

在通用规则之外再加一条只匹配仓库名 `ci` 的规则集：

- 批准数先设为 1，不要求 last push approval。
- 同样只允许 squash 和 rebase，并要求线性历史。
- 额外状态检查 `lint-workflows`，`integration_id` 同样是 15368。
- 同一个组织管理员 bypass，模式仍是 `pull_request`。

防作弊 job 只在仓库和工作流定义都是 `burncloud/ci` 时记录命中而不失败，否则这里改不了 `.github/`。补偿就是上面的审批和 bypass 审计，而不是把批准数抬到 2。

## 导入

确认 JSON 后手工执行。不要让自动化套用。

```bash
gh api --method POST /orgs/burncloud/rulesets --input burncloud-main.json
gh api --method POST /orgs/burncloud/rulesets --input burncloud-ci.json
```

把下面的 `refs/tags/v0.0.0` 换成真实的不可变 tag 或 SHA 再导入。

### burncloud-main.json

```json
{
  "name": "burncloud-main",
  "target": "branch",
  "enforcement": "evaluate",
  "bypass_actors": [
    {
      "actor_id": 1,
      "actor_type": "OrganizationAdmin",
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    },
    "repository_name": {
      "include": ["~ALL"],
      "exclude": []
    }
  },
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "required_linear_history"},
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["squash", "rebase"]
      }
    },
    {
      "type": "workflows",
      "parameters": {
        "do_not_enforce_on_create": true,
        "workflows": [
          {
            "repository_id": 1469670652,
            "path": ".github/workflows/rust.yml",
            "ref": "refs/tags/v0.0.0"
          }
        ]
      }
    }
  ]
}
```

在外部 crate 仓库核对出 required workflow 的真实检查名之前，不把同名 `required_status_checks` 和上面的 `workflows` 规则放在一起。名字若对不上，所有 PR 会一直等一个不会出现的检查。

### burncloud-ci.json

```json
{
  "name": "burncloud-ci",
  "target": "branch",
  "enforcement": "evaluate",
  "bypass_actors": [
    {
      "actor_id": 1,
      "actor_type": "OrganizationAdmin",
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    },
    "repository_name": {
      "include": ["ci"],
      "exclude": []
    }
  },
  "rules": [
    {"type": "required_linear_history"},
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["squash", "rebase"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": true,
        "required_status_checks": [
          {"context": "lint-workflows", "integration_id": 15368}
        ]
      }
    }
  ]
}
```
