# 组织规则集（只作建议，不要直接应用）

下面是给 `burncloud` 组织的规则集草案。本仓库的变更不会调用 GitHub API 去创建或修改规则集，也不会改其他仓库。导入前先通读；建议先用 `enforcement: evaluate`，确认 pull request 上的检查名和这里一致后，再把 `enforcement` 改成 `active`。

检查名假设每个 crate 的调用方 job id 是 `rust`：

```yaml
jobs:
  rust:
    uses: burncloud/ci/.github/workflows/rust.yml@v1
```

这时必需状态检查是：

- `rust / lint / fmt`
- `rust / lint / clippy`
- `rust / lint / unsafe`
- `rust / test / cargo-test`
- `rust / test / doc-test`
- `rust / test / proptest`
- `rust / test / fuzz`
- `rust / test / mutants`
- `rust / supply-chain / deny`
- `rust / supply-chain / audit`
- `rust / supply-chain / vet`
- `rust / api / semver`
- `rust / api / capabilities`
- `rust / protect / protected-paths`

`proptest`、`fuzz`、`mutants` 默认会成功退出并在日志里说明已跳过，所以可以把它们列进必需检查，而不会挡住还没有这些测试的 crate。

如果第一次在 `burncloud/ci` 上跑出来的名字和上表不同，以 Actions 页面上的名字为准，改完这条文档再把规则集改成 `active`。

## 所有仓库的默认分支

- 禁止删除默认分支。
- 禁止强推（`non_fast_forward`）。
- 必须通过 pull request 才能更新默认分支，从而禁止直接推送。
- 至少一个批准；新的提交使旧批准失效。
- 只允许 squash 和 rebase，配合线性历史，避免合并提交。
- 要求线性历史。
- 要求上表里的状态检查，并且分支必须包含最新的默认分支（`strict_required_status_checks_policy: true`）。
- 不配置 `bypass_actors`。组织规则集下，仓库管理员不能自行绕过。

`burncloud/ci` 也包含在这条规则里。防作弊 job 对本仓库同一仓库来的变更只记录、不失败，所以下面还有一条只针对 `ci` 的更严审批。

## `burncloud/ci` 额外保护

- 在通用规则之上，再要求两次批准。
- `require_last_push_approval`：最后一次推送不能由推送者自己批准。
- 额外必需检查：`lint-workflows`（actionlint、shellcheck 和脚本正反例）。
- 仍然不配置 bypass。

防作弊层故意不阻断这个仓库对 `.github/`、`deny.toml`、`supply-chain/` 的修改，否则共享工作流无法再通过 pull request 更新。补偿就是这里的两次批准和最后一次推送的独立批准。fork 上的 pull request 不在豁免范围内。

可选：等维护者稳定后再加 `CODEOWNERS`，并把 `require_code_owner_review` 设为 true。没有 CODEOWNERS 时打开这个开关不会多出审查者，所以草案里保持 false。

## 不要同时启用的 required workflow

规则类型 `workflows` 可以要求 `burncloud/ci` 里某个 ref 上的工作流必须通过，调用方改自己的 YAML 也换不掉它，inputs 使用工作流默认值。`repository_id` 是 `1469670652`。

这条和「每个 crate 自己 `uses` 一次」会各跑一整套 CI。只选一种。草案把必需状态检查配在调用方 `uses` 的名字上；required workflow 单独放在第三个 JSON 里，默认不要和第一条一起启用。`v1` 标签不存在时，required workflow 会挡住所有 pull request。

## 导入

确认 JSON 后手工执行，不要让自动化直接套用：

```bash
gh api --method POST /orgs/burncloud/rulesets --input burncloud-main.json
gh api --method POST /orgs/burncloud/rulesets --input burncloud-ci.json
```

### burncloud-main.json

```json
{
  "name": "burncloud-main",
  "target": "branch",
  "enforcement": "evaluate",
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
    {
      "type": "deletion"
    },
    {
      "type": "non_fast_forward"
    },
    {
      "type": "required_linear_history"
    },
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
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          {"context": "rust / lint / fmt"},
          {"context": "rust / lint / clippy"},
          {"context": "rust / lint / unsafe"},
          {"context": "rust / test / cargo-test"},
          {"context": "rust / test / doc-test"},
          {"context": "rust / test / proptest"},
          {"context": "rust / test / fuzz"},
          {"context": "rust / test / mutants"},
          {"context": "rust / supply-chain / deny"},
          {"context": "rust / supply-chain / audit"},
          {"context": "rust / supply-chain / vet"},
          {"context": "rust / api / semver"},
          {"context": "rust / api / capabilities"},
          {"context": "rust / protect / protected-paths"}
        ]
      }
    }
  ]
}
```

### burncloud-ci.json

```json
{
  "name": "burncloud-ci",
  "target": "branch",
  "enforcement": "evaluate",
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
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 2,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": true,
        "required_review_thread_resolution": false
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          {"context": "lint-workflows"}
        ]
      }
    }
  ]
}
```

### 可选，默认不要和 burncloud-main 一起启用

`ref` 在打出 `v1` 之前不要用。启用时把 `enforcement` 改成 `active`，并去掉 crate 仓库里重复的 `uses`，否则 CI 跑两遍。required workflow 的检查名没有调用方 job id 前缀，必需状态检查要改成 `lint / fmt` 这种两段名字，而不是 `rust / lint / fmt`。

```json
{
  "name": "burncloud-required-workflow",
  "target": "branch",
  "enforcement": "evaluate",
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    },
    "repository_name": {
      "include": ["~ALL"],
      "exclude": ["ci"]
    }
  },
  "rules": [
    {
      "type": "workflows",
      "parameters": {
        "do_not_enforce_on_create": true,
        "workflows": [
          {
            "repository_id": 1469670652,
            "path": ".github/workflows/rust.yml",
            "ref": "refs/tags/v1"
          }
        ]
      }
    }
  ]
}
```
