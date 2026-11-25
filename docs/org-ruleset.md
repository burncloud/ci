# 规则集（只作建议，不要直接应用）

不升级 GitHub Team，走免费套餐。下面的 JSON 只放在文档里。不要用它调用规则集 API，也不要把它应用到 `burncloud` 组织或任何仓库。`enforcement` 保持 `evaluate`。人确认检查都出现之后，再改成 `active`。

组织级规则集（包括 required workflow）需要 GitHub Team 或 Enterprise。这跟仓库是否公开无关。

免费套餐采用四件事：清单仓库保持公开、`uses` 引用钉完整 SHA 或不可变 tag、单仓库规则集、CODEOWNERS。组织级方案留在本文后半，作为升级到 Team 之后的选项。

## 免费套餐：清单仓库

清单仓库必须公开。免费套餐下，私有仓库用不了规则集，也用不了分支保护。

调用方工作流用 `uses: burncloud/ci/.github/workflows/rust.yml@<40 位 SHA 或不可变 tag>`。工作流不要命名为 `Rust`。

PR 作者可以修改调用方的 `ci.yml`：换掉 `uses`、改 `protected-paths`，或写一个同名空 job。单仓库规则集挡不住这份 YAML。安全性靠 CODEOWNERS 审批兜底。`.github/workflows/` 和 `CODEOWNERS` 本身都要写进 CODEOWNERS，改工作流必须有 Code Owner 批准。审批人用哪个账号由仓库所有者决定，这里不指定。

```
# 把 @OWNER 换成所有者指定的用户或团队
/.github/workflows/** @OWNER
/.github/CODEOWNERS @OWNER
```

`burncloud/template` 的 PR #1 用 job id `rust` 调用了 `rust.yml`（https://github.com/burncloud/template/actions/runs/45630856560）。实测检查名是带 `rust / ` 前缀的三段式。`rust / resolve` 在 `working-directory` 使用默认 `.` 时会跳过，跳过的检查不能满足必需状态检查，所以不放进规则集。

main 上的单仓库规则集配这些：

- 禁止直接推送，禁止强推，必须走 pull request。
- 必需状态检查用下面这些实测的 `rust / ...` 名字，每条都绑定 `integration_id` `15368`。
- 至少 1 人审批，并且要求 Code Owner 审批。
- 推了新提交后旧批准失效，必须重新审批。

```json
{
  "name": "crate-main",
  "target": "branch",
  "enforcement": "evaluate",
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "rules": [
    {"type": "non_fast_forward"},
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "do_not_enforce_on_create": true,
        "required_status_checks": [
          {"context": "rust / lint / fmt", "integration_id": 15368},
          {"context": "rust / lint / clippy", "integration_id": 15368},
          {"context": "rust / lint / unsafe", "integration_id": 15368},
          {"context": "rust / test / cargo-test", "integration_id": 15368},
          {"context": "rust / test / doc-test", "integration_id": 15368},
          {"context": "rust / test / cargo-doc", "integration_id": 15368},
          {"context": "rust / test / msrv", "integration_id": 15368},
          {"context": "rust / test / extra-targets", "integration_id": 15368},
          {"context": "rust / test / wit", "integration_id": 15368},
          {"context": "rust / test / proptest", "integration_id": 15368},
          {"context": "rust / test / fuzz", "integration_id": 15368},
          {"context": "rust / test / mutants", "integration_id": 15368},
          {"context": "rust / supply-chain / deny", "integration_id": 15368},
          {"context": "rust / supply-chain / audit", "integration_id": 15368},
          {"context": "rust / supply-chain / vet", "integration_id": 15368},
          {"context": "rust / api / semver", "integration_id": 15368},
          {"context": "rust / api / capabilities", "integration_id": 15368},
          {"context": "rust / protect / protected-paths", "integration_id": 15368}
        ]
      }
    }
  ]
}
```

确认 JSON 后由人在对应公开仓库手工创建。不要让自动化套用。job id 不是 `rust` 时，检查名的第一段会跟着变，规则集要改成实测名字。

## 升级到 Team 之后：组织级 required workflow

调用方仓库里的 YAML 挡不住改检查。有人可以在 PR 里把 `protected-paths` 改空、换掉 `uses`，或写一个同名空 job 凑状态检查。只配 `required_status_checks` 也不够：不写 `integration_id` 时，普通 commit status 可以冒充通过。

升级后用规则类型 `workflows`，要求 `burncloud/ci` 里某个不可变 ref 上的 `.github/workflows/rust.yml` 必须通过。`repository_id` 是 `1469670652`。ref 用 `refs/tags/vX.Y.Z` 或 40 位 SHA，不要用会移动的 `v1`。

这一节是升级之后的选项，现在不导入。

这条规则直接运行本仓库的 `rust.yml`，不会传入 inputs。`working-directory`、开关和 semver 基线在表达式里用 `||` 落到空值或 `auto`；受保护路径输入为空时，脚本使用自己的默认列表。调用方因此改不了这套默认行为。不要再同时让每个 crate 仓库用 `uses` 跑一遍，否则 CI 会跑两遍。规则集启用 required workflow 之后，`burncloud/template` 里的 `uses` job 要删掉。调用方文件可以留着给人读，但安全边界是这条规则。

`burncloud/template` 的 PR #1 用 job id `rust` 调用了 `rust.yml`（https://github.com/burncloud/template/actions/runs/45630856560）。检查名是带 `rust / ` 前缀的三段式，另有 `rust / resolve`：

- `rust / resolve`
- `rust / lint / fmt`
- `rust / lint / clippy`
- `rust / lint / unsafe`
- `rust / test / cargo-test`
- `rust / test / doc-test`
- `rust / test / cargo-doc`
- `rust / test / msrv`
- `rust / test / extra-targets`
- `rust / test / wit`
- `rust / test / proptest`
- `rust / test / fuzz`
- `rust / test / mutants`
- `rust / supply-chain / deny`
- `rust / supply-chain / audit`
- `rust / supply-chain / vet`
- `rust / api / semver`
- `rust / api / capabilities`
- `rust / protect / protected-paths`

通过 required workflow 注入时不经过这个 job id，检查名还没有核对，**待验证**。在那之前，下面的 JSON 不包含 `required_status_checks`，避免名字对不上时所有 PR 被永远卡住。

## 多个 working-directory

required workflow 一次只用一个 `working-directory`，默认是仓库根。一个仓库里有多个 crate 时：

- 优先拆成每个 crate 一个仓库。免费套餐下每个仓库用自己的 `uses` 和单仓库规则集。升级到 Team 之后可以改用组织级 required workflow。
- 必须放在一起时，不要共用一个叫 `rust` 的 job。每个目录一个 job，检查名会变成 `<job id> / lint / fmt` 这种三段名字。规则集得按这些真实名字逐个填写。一条钉在 `rust.yml` 上的 required workflow 覆盖不了多个目录。两次调用看到的 `github.workflow` 相同，还要传不同的 `concurrency-key`，否则后一次会取消整次运行。

```yaml
jobs:
  foo:
    uses: burncloud/ci/.github/workflows/rust.yml@vX.Y.Z
    with:
      working-directory: crates/foo
      concurrency-key: foo
  bar:
    uses: burncloud/ci/.github/workflows/rust.yml@vX.Y.Z
    with:
      working-directory: crates/bar
      concurrency-key: bar
```

## 谁来批准

下面到文末仍是组织级规则集，升级到 Team 之前不导入。

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
