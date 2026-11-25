# 规则集（只作建议，不要直接应用）

不升级 GitHub Team，走免费套餐。JSON 放在 [docs/rulesets](rulesets)。不要用它调用规则集 API，也不要把它应用到 `burncloud` 组织或任何仓库。

免费套餐的仓库规则集只有 `disabled` 和 `active`。先以 `disabled` 建立，用读回命令核对返回值，再由人改成 `active`。Evaluate 只有 Enterprise Cloud 有，免费套餐和 Team 都没有这个状态，这里不用。

组织级规则集（包括 required workflow）需要 GitHub Team 或 Enterprise。这跟仓库是否公开无关。

免费套餐采用四件事：清单仓库保持公开、`uses` 只引用 40 位完整 SHA 或 `vX.Y.Z` 标签、单仓库规则集、CODEOWNERS。禁止 `v1` 这类浮动标签，也禁止分支名。组织级方案留在本文后半，作为升级到 Team 之后的选项。

## 免费套餐：清单仓库

清单仓库必须公开。免费套餐下，私有仓库用不了规则集，也用不了分支保护。

调用方工作流用 `uses: burncloud/ci/.github/workflows/rust.yml@<40 位 SHA 或 vX.Y.Z>`。工作流不要命名为 `Rust`。

PR 作者可以修改调用方的 `ci.yml`：换掉 `uses`、改 `protected-paths`，或写一个同名空 job。单仓库规则集挡不住这份 YAML。安全性靠 CODEOWNERS 审批兜底。`.github/workflows/` 和 `CODEOWNERS` 本身都要写进 CODEOWNERS，改工作流必须有 Code Owner 批准。

`rustburn` 负责写代码，是 owner。紧急时走仓库管理员的 `pull_request` bypass，不能直推。`ivories`（GitHub id `12606587`）负责审批，是 Code Owner。

```
/.github/workflows/** @rustburn @ivories
/.github/CODEOWNERS @rustburn @ivories
```

`burncloud/template` 的 PR #1 用 job id `rust` 调用了 `rust.yml`（https://github.com/burncloud/template/actions/runs/45630856560）。实测检查名是带 `rust / ` 前缀的三段式。`rust / resolve` 在 `working-directory` 为默认 `.` 时会被跳过。跳过的 job 会以 Success 报告，把它设为必需检查没有意义，所以不放进规则集。

[docs/rulesets/crate-main.json](rulesets/crate-main.json) 配这些：

- 禁止删除默认分支，禁止强推。必须走 pull request，从而禁止直接推送。
- 必需状态检查用实测的 `rust / ...` 名字，每条都绑定 `integration_id` `15368`。
- 至少 1 人审批，并且要求 Code Owner 审批。推了新提交后旧批准失效。最后一次推送的人不能充当这次的批准。未解决的 review 线程会挡住合并。
- `bypass_actors` 是仓库管理员（`RepositoryRole`，`actor_id` `5`），`bypass_mode` 是 `pull_request`。`protected-paths` 是必需检查，改 `.github/` 或工具链的 PR 本来永远合不进。管理员只能在 PR 里绕过，不能直推。`pull_request` 这个模式只对分支规则集有效。
- `enforcement` 是 `disabled`。

job id 不是 `rust` 时，检查名的第一段会跟着变，规则集要改成实测名字。

在 `burncloud/ci` 的检出里执行。`{owner}` 和 `{repo}` 换成清单仓库。建仓流程从同一个 CI_REF 下载 `scripts/check-ruleset-readback.sh` 再执行。读回先按文件里的 `disabled` 核对；改成 `active` 之后用 `EXPECTED_ENFORCEMENT=active` 再核对一次。仓库里的文件保持 `disabled`，不要把 `active` 提交进来。

```bash
id=$(gh api -X POST repos/{owner}/{repo}/rulesets --input docs/rulesets/crate-main.json --jq .id)
gh api "repos/{owner}/{repo}/rulesets/${id}" > /tmp/crate-main.readback.json
bash scripts/check-ruleset-readback.sh docs/rulesets/crate-main.json /tmp/crate-main.readback.json
jq '.enforcement = "active"' docs/rulesets/crate-main.json | gh api -X PUT "repos/{owner}/{repo}/rulesets/${id}" --input -
gh api "repos/{owner}/{repo}/rulesets/${id}" > /tmp/crate-main.readback.json
EXPECTED_ENFORCEMENT=active bash scripts/check-ruleset-readback.sh docs/rulesets/crate-main.json /tmp/crate-main.readback.json
```

## 免费套餐：burncloud/ci

本仓库的 main 用 [docs/rulesets/ci-main.json](rulesets/ci-main.json)。规则和 `crate-main` 相同：pull request、1 个批准、Code Owner、新提交使旧批准失效、last push approval、review 线程必须解决、禁止强推、禁止删除分支。bypass 同样是仓库管理员的 `pull_request` 模式，原因相同。`enforcement` 是 `disabled`。

`.github/CODEOWNERS` 把全部路径交给 `@rustburn` 和 `@ivories`。`rustburn` 负责写代码，是 owner，紧急时走仓库管理员的 `pull_request` bypass。`ivories`（GitHub id `12606587`）负责审批，是 Code Owner。两人在 GitHub 上都要有写权限。`gh api repos/burncloud/ci/codeowners/errors` 返回的 `errors` 为空才算配好。

必需检查用本仓库 PR 上实测会跑起来的名字，每条 `integration_id` 都是 `15368`：`lint-workflows`、直接触发的 `resolve` 和两段式名字、`ci.yml` 里 `rust` 与 `caller` 两次调用的三段式名字。`rust / resolve` 和 `caller / resolve` 会跳过并以 Success 报告，设为必需没有意义，所以不在名单里。

标签不能和创建放在同一份规则集里。`bypass_actors` 作用在整份规则集上，不是单条规则。`pull_request` 模式只适用于分支规则集，标签上不能用。`always` 会绕过该规则集里的每一条规则，不只是 creation。因此拆成两份：

- [docs/rulesets/ci-tags.json](rulesets/ci-tags.json) 匹配 `refs/tags/v*`，规则是 `update`（`update_allows_fetch_and_merge` 为 false，这是 API 的必填参数）、`deletion`、`non_fast_forward`。`bypass_actors` 为空，仓库管理员也不能移动或删除这些标签。移动标签是 ref 的 `update`，`non_fast_forward` 再挡住非快进更新。
- [docs/rulesets/ci-tags-create.json](rulesets/ci-tags-create.json) 只有 `creation`。bypass 是同一个仓库管理员角色，`bypass_mode` 为 `always`。creation 的含义是：只有能 bypass 的人可以创建匹配的 tag。

三份的 `enforcement` 都是 `disabled`。在 `burncloud/ci` 的检出里执行。读回用 `scripts/check-ruleset-readback.sh`：没有 `pull_request` 或 `required_status_checks` 的标签规则集也按同一套规则比较。

```bash
main_id=$(gh api -X POST repos/burncloud/ci/rulesets --input docs/rulesets/ci-main.json --jq .id)
tags_id=$(gh api -X POST repos/burncloud/ci/rulesets --input docs/rulesets/ci-tags.json --jq .id)
create_id=$(gh api -X POST repos/burncloud/ci/rulesets --input docs/rulesets/ci-tags-create.json --jq .id)
gh api "repos/burncloud/ci/rulesets/${main_id}" > /tmp/ci-main.readback.json
bash scripts/check-ruleset-readback.sh docs/rulesets/ci-main.json /tmp/ci-main.readback.json
gh api "repos/burncloud/ci/rulesets/${tags_id}" > /tmp/ci-tags.readback.json
bash scripts/check-ruleset-readback.sh docs/rulesets/ci-tags.json /tmp/ci-tags.readback.json
gh api "repos/burncloud/ci/rulesets/${create_id}" > /tmp/ci-tags-create.readback.json
bash scripts/check-ruleset-readback.sh docs/rulesets/ci-tags-create.json /tmp/ci-tags-create.readback.json
jq '.enforcement = "active"' docs/rulesets/ci-main.json | gh api -X PUT "repos/burncloud/ci/rulesets/${main_id}" --input -
gh api "repos/burncloud/ci/rulesets/${main_id}" > /tmp/ci-main.readback.json
EXPECTED_ENFORCEMENT=active bash scripts/check-ruleset-readback.sh docs/rulesets/ci-main.json /tmp/ci-main.readback.json
jq '.enforcement = "active"' docs/rulesets/ci-tags.json | gh api -X PUT "repos/burncloud/ci/rulesets/${tags_id}" --input -
gh api "repos/burncloud/ci/rulesets/${tags_id}" > /tmp/ci-tags.readback.json
EXPECTED_ENFORCEMENT=active bash scripts/check-ruleset-readback.sh docs/rulesets/ci-tags.json /tmp/ci-tags.readback.json
jq '.enforcement = "active"' docs/rulesets/ci-tags-create.json | gh api -X PUT "repos/burncloud/ci/rulesets/${create_id}" --input -
gh api "repos/burncloud/ci/rulesets/${create_id}" > /tmp/ci-tags-create.readback.json
EXPECTED_ENFORCEMENT=active bash scripts/check-ruleset-readback.sh docs/rulesets/ci-tags-create.json /tmp/ci-tags-create.readback.json
```

不要把改成 `active` 的 JSON 提交回仓库。

`ci-tags` 没有 bypass。规则集处于 `active` 时，谁都不能移动或删除 `v*` 标签。打错标签时，由组织 owner 临时关掉这份规则集，处理完立刻恢复。GitHub 会在组织审计日志里留下这次 ruleset 更新。已经被下游用来钉住的 `vX.Y.Z` 不要移动，应该发一个新的补丁版本。只有确认还没有人钉住这个标签时，才删除或在正确提交上重建。

组织 owner 先把 `ci-tags` 临时改成 `disabled`：

```bash
id=$(gh api repos/burncloud/ci/rulesets --jq '.[] | select(.name=="ci-tags") | .id')
jq '.enforcement = "disabled"' docs/rulesets/ci-tags.json | gh api -X PUT "repos/burncloud/ci/rulesets/${id}" --input -
gh api "repos/burncloud/ci/rulesets/${id}" > /tmp/ci-tags.readback.json
bash scripts/check-ruleset-readback.sh docs/rulesets/ci-tags.json /tmp/ci-tags.readback.json
```

确认还没有下游钉住这个标签时，删掉它，或者删掉后在正确提交上重建。已经钉住的不要执行这两段，改发下一个补丁版本。

```bash
gh api -X DELETE "repos/burncloud/ci/git/refs/tags/vX.Y.Z"
```

```bash
gh api -X DELETE "repos/burncloud/ci/git/refs/tags/vX.Y.Z"
gh api -X POST repos/burncloud/ci/git/refs -f ref="refs/tags/vX.Y.Z" -f sha="<40 位正确提交>"
```

处理完立刻恢复 `active` 并读回。确认 `enforcement` 是 `active`，并且 `bypass_actors` 仍是空的：

```bash
id=$(gh api repos/burncloud/ci/rulesets --jq '.[] | select(.name=="ci-tags") | .id')
jq '.enforcement = "active"' docs/rulesets/ci-tags.json | gh api -X PUT "repos/burncloud/ci/rulesets/${id}" --input -
gh api "repos/burncloud/ci/rulesets/${id}" > /tmp/ci-tags.readback.json
EXPECTED_ENFORCEMENT=active bash scripts/check-ruleset-readback.sh docs/rulesets/ci-tags.json /tmp/ci-tags.readback.json
```

## 升级到 Team 之后：组织级 required workflow

调用方仓库里的 YAML 挡不住改检查。有人可以在 PR 里把 `protected-paths` 改空、换掉 `uses`，或写一个同名空 job 凑状态检查。只配 `required_status_checks` 也不够：不写 `integration_id` 时，普通 commit status 可以冒充通过。

升级后用规则类型 `workflows`，要求 `burncloud/ci` 里某个 ref 上的 `.github/workflows/rust.yml` 必须通过。`repository_id` 是 `1469670652`。ref 只允许 `refs/tags/vX.Y.Z` 或 40 位 SHA。禁止 `v1` 这类浮动标签，也禁止分支名。

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

`rustburn` 负责写代码，是 owner。紧急时他用仓库管理员或组织管理员的 `pull_request` bypass，不能直推。`ivories`（GitHub id `12606587`）负责审批，是 Code Owner。组织管理员 bypass 是规则集 API 的行为，不是额外开的口子。组织级规则集也先以 `disabled` 建立，人工核对读回结果后再改为 `active`。

`bypass_actors` 保留全体组织管理员，`actor_type` 是 `OrganizationAdmin`，`actor_id` 用 `1`，`bypass_mode` 是 `pull_request`。导入前如果 API 拒绝这个 id，以组织设置页面导出的值为准。`require_last_push_approval` 先保持 false。

## 所有仓库的默认分支

- 禁止删除默认分支，禁止强推。
- 必须走 pull request，从而禁止直接推送。
- 至少一个来自非作者主体的批准。新提交使旧批准失效。
- 只允许 squash 和 rebase，并要求线性历史。
- required workflow 如上。在外部仓库核对出真实检查名之前，不配 `required_status_checks`。
- 分支必须包含最新的默认分支。

## `burncloud/ci`

免费套餐下不要用这一节保护本仓库。本仓库用上面的 `ci-main`、`ci-tags` 和 `ci-tags-create`。下面这份组织 JSON 只在升级到 Team 之后才可能导入，而且必需检查不能只留 `lint-workflows`，要换成 `ci-main.json` 里的实测名字。

在通用规则之外再加一条只匹配仓库名 `ci` 的规则集。文件里现在的必需检查只有 `lint-workflows`。导入前改成 `ci-main.json` 里的实测名字，并把批准、Code Owner、last push approval 和线程解决跟 `ci-main.json` 对齐。bypass 仍是组织管理员，模式是 `pull_request`。

防作弊 job 只在仓库和工作流定义都是 `burncloud/ci` 时记录命中而不失败，否则这里改不了 `.github/`。补偿就是上面的审批和 bypass 审计，而不是把批准数抬到 2。

## 导入

确认 JSON 后手工执行。不要让自动化套用。

`{id}` 用创建返回值。文件里的 `enforcement` 是 `disabled`。读回核对后再把 enforcement 改成 `active` 做 PUT，不要把 `active` 提交回仓库。

```bash
main_id=$(gh api -X POST orgs/burncloud/rulesets --input docs/rulesets/burncloud-main.json --jq .id)
ci_id=$(gh api -X POST orgs/burncloud/rulesets --input docs/rulesets/burncloud-ci.json --jq .id)
gh api "orgs/burncloud/rulesets/${main_id}" > /tmp/burncloud-main.readback.json
bash scripts/check-ruleset-readback.sh docs/rulesets/burncloud-main.json /tmp/burncloud-main.readback.json
gh api "orgs/burncloud/rulesets/${ci_id}" > /tmp/burncloud-ci.readback.json
bash scripts/check-ruleset-readback.sh docs/rulesets/burncloud-ci.json /tmp/burncloud-ci.readback.json
jq '.enforcement = "active"' docs/rulesets/burncloud-main.json | gh api -X PUT "orgs/burncloud/rulesets/${main_id}" --input -
gh api "orgs/burncloud/rulesets/${main_id}" > /tmp/burncloud-main.readback.json
EXPECTED_ENFORCEMENT=active bash scripts/check-ruleset-readback.sh docs/rulesets/burncloud-main.json /tmp/burncloud-main.readback.json
jq '.enforcement = "active"' docs/rulesets/burncloud-ci.json | gh api -X PUT "orgs/burncloud/rulesets/${ci_id}" --input -
gh api "orgs/burncloud/rulesets/${ci_id}" > /tmp/burncloud-ci.readback.json
EXPECTED_ENFORCEMENT=active bash scripts/check-ruleset-readback.sh docs/rulesets/burncloud-ci.json /tmp/burncloud-ci.readback.json
```

把 [docs/rulesets/burncloud-main.json](rulesets/burncloud-main.json) 里的 `refs/tags/v0.0.0` 换成真实的 `vX.Y.Z` 或 40 位 SHA 再导入。禁止 `v1` 和分支名。

[docs/rulesets/burncloud-main.json](rulesets/burncloud-main.json) 是默认分支的组织规则集。在外部 crate 仓库核对出 required workflow 的真实检查名之前，不把同名 `required_status_checks` 和 `workflows` 规则放在一起。名字若对不上，所有 PR 会一直等一个不会出现的检查。

[docs/rulesets/burncloud-ci.json](rulesets/burncloud-ci.json) 只匹配仓库名 `ci`。它不是免费套餐下本仓库的保护方案。
