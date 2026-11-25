# 组织规则集（只作建议，不要直接应用）

下面的 JSON 只放在文档里。不要用它调用规则集 API，也不要把它应用到 `burncloud` 组织。`enforcement` 保持 `evaluate`。在打出不可变 tag 或选定 SHA 之前，不要改成 `active`。

## 主方案：required workflow

调用方仓库里的 YAML 挡不住改检查。有人可以在 PR 里把 `protected-paths` 改空、换掉 `uses`，或写一个同名空 job 凑状态检查。只配 `required_status_checks` 也不够：不写 `integration_id` 时，普通 commit status 可以冒充通过。

主方案是规则类型 `workflows`，要求 `burncloud/ci` 里某个不可变 ref 上的 `.github/workflows/rust.yml` 必须通过。`repository_id` 是 `1469670652`。ref 用 `refs/tags/vX.Y.Z` 或 40 位 SHA，不要用会移动的 `v1`。

这条规则跑的是本仓库的工作流，inputs 用默认值，调用方改不了路径列表。不要再同时让每个 crate 仓库用 `uses` 跑一遍，否则 CI 会跑两遍。调用方文件可以留着给人读，但安全边界是这条规则。

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

这些两段式名字是按 job id 推断的，**待用真实 crate 仓库验证**。在外部仓库看到真实名字之前，不要把规则集改成 `active`。本仓库自己的 `ci.yml` 用 job id `rust` 再调用一次，那一组名字会多一个 `rust /` 前缀；那是调用方前缀，不是 required workflow 的名字。

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

批准必须来自 PR 作者以外的主体：另一个独立账号、专门的 review 账号，或 GitHub App。现在的 PR 作者是 `rustburn`。如果组织里能批准的人只有他一个，他不能既写 PR 又当唯一审批人。这种时候保持 `evaluate`，不要改成 `active`。

`bypass_actors` 保留全体组织管理员，`actor_type` 是 `OrganizationAdmin`，`actor_id` 用 `1`，`bypass_mode` 是 `pull_request`。这只给紧急情况用，并且只在 pull request 上绕过，会留下 bypass 记录。导入前如果 API 拒绝这个 id，以组织设置页面导出的值为准。`require_last_push_approval` 先保持 false；有了第二个审批人再打开，否则作者无法让别人批准自己刚推的提交。

## 所有仓库的默认分支

- 禁止删除默认分支，禁止强推。
- 必须走 pull request，从而禁止直接推送。
- 至少一个来自非作者主体的批准。新提交使旧批准失效。
- 只允许 squash 和 rebase，并要求线性历史。
- required workflow 如上。状态检查如果要列，每条都带 `"integration_id": 15368`，避免 commit status 伪造。
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
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": true,
        "required_status_checks": [
          {"context": "lint / fmt", "integration_id": 15368},
          {"context": "lint / clippy", "integration_id": 15368},
          {"context": "lint / unsafe", "integration_id": 15368},
          {"context": "test / cargo-test", "integration_id": 15368},
          {"context": "test / doc-test", "integration_id": 15368},
          {"context": "test / cargo-doc", "integration_id": 15368},
          {"context": "test / msrv", "integration_id": 15368},
          {"context": "test / extra-targets", "integration_id": 15368},
          {"context": "test / wit", "integration_id": 15368},
          {"context": "test / proptest", "integration_id": 15368},
          {"context": "test / fuzz", "integration_id": 15368},
          {"context": "test / mutants", "integration_id": 15368},
          {"context": "supply-chain / deny", "integration_id": 15368},
          {"context": "supply-chain / audit", "integration_id": 15368},
          {"context": "supply-chain / vet", "integration_id": 15368},
          {"context": "api / semver", "integration_id": 15368},
          {"context": "api / capabilities", "integration_id": 15368},
          {"context": "protect / protected-paths", "integration_id": 15368}
        ]
      }
    }
  ]
}
```

上面的 `context` 与 `burncloud/ci` 上 `rust.yml` 顶层运行看到的名字一致。同一个 required workflow 进到其他 crate 仓库后的名字，打 v1 前仍待验证。

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
