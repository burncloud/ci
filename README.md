# burncloud/ci

BurnCloud 各 Rust crate 仓库共用的可复用 GitHub Actions 工作流。规则只改这里，调用方通过 `workflow_call` 引用。

调用方仓库只需要：

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  rust:
    uses: burncloud/ci/.github/workflows/rust.yml@v1
```

job id 必须是 `rust`。组织规则集里的必需状态检查按这个前缀命名，见 [docs/org-ruleset.md](docs/org-ruleset.md)。

`working-directory` 默认是仓库根。crate 不在根目录时：

```yaml
jobs:
  rust:
    uses: burncloud/ci/.github/workflows/rust.yml@v1
    with:
      working-directory: crates/foo
```

## 版本怎么固定

发布时在目标提交上打不可移动的 `vX.Y.Z`，再把主版本标签 `v1` 移到同一提交。已经发出的 `vX.Y.Z` 不要移动；打错了就发下一个补丁版本。

```bash
git tag v1.0.0 <sha>
git push origin v1.0.0
git tag -f v1 <sha>
git push -f origin v1
```

调用方有两种钉法：

| 引用 | 行为 |
| --- | --- |
| `@v1` | 维护者移动 `v1` 之后，各仓库下一次运行就用上这一主版本里的修复。标签会变，信任边界是有权限移动 `v1` 的人。 |
| `@<40 位 SHA>` | 指向一次提交，不会跟着变。修复要调用方自己改 SHA。 |

组织规则集里的 required workflow 建议用 `refs/tags/v1`，取舍与上面相同。第一个 `v1` 打出来之前不要启用那条规则。

本仓库里的 action 都钉死到完整提交 SHA，注释里写发行标签。`dtolnay/rust-toolchain` 的 `v1` 标签会移动，所以钉的是 2026-11-15 的提交 `df2a88e9fe4098bad09cb42c3dec7187f15861fc`。cargo 子命令优先用 `taiki-e/install-action` `v2.90.8`（`fe3acb53a98b62c772db35de75ce0e4595e7ca8c`），并写上工具版本、`fallback: none`。cargo-fuzz 不在这个 action 的清单里，用 `cargo install --locked cargo-fuzz@0.13.2`。

当前工具版本：cargo-deny 0.22.0、cargo-audit 0.23.0、cargo-vet 0.10.3、cargo-semver-checks 0.51.0、cargo-mutants 27.1.0、cargo-fuzz 0.13.2。cargo-vet 钉 0.10.3 是因为 install-action v2.90.8 的校验清单里最新就是 0.10.3。

`burncloud/ci` 需要保持 public。调用方用默认 `GITHUB_TOKEN` 读不了其他私有仓库，默认 `deny.toml` 和检查脚本是从本仓库的原始文件地址按 `job.workflow_sha` 下载的。

## 五层

汇总工作流是 [`.github/workflows/rust.yml`](.github/workflows/rust.yml)，它再调用下面五个文件。权限都是 `contents: read`。防作弊层不 checkout 调用方仓库。

### 1. 格式与静态检查 `lint.yml`

| job | 做什么 |
| --- | --- |
| `fmt` | `cargo fmt --all --check` |
| `clippy` | `cargo clippy --workspace --all-targets --all-features -- -D warnings -W clippy::pedantic`。pedantic 打开后再把全部警告当错误。 |
| `unsafe` | 每个 lib/bin 根文件必须有一行 `#![forbid(unsafe_code)]`。再用整词搜索 `unsafe`。`unsafe_code` 不是独立单词，属性本身不会被这次搜索命中。 |

inputs：`toolchain`（默认 `stable`）、`working-directory`（默认 `.`）。

### 2. 测试 `test.yml`

| job | 做什么 |
| --- | --- |
| `cargo-test` | `cargo test --workspace --all-targets` |
| `doc-test` | `cargo test --workspace --doc` |
| `proptest` | 默认关。打开后若 Cargo.toml 没有 `proptest` 依赖，失败并说明原因；有依赖则设 `PROPTEST_CASES=256` 再跑测试。 |
| `fuzz` | 默认关。打开后若没有 `fuzz/Cargo.toml` 或 `fuzz/fuzz_targets/*.rs`，失败并说明原因。有目标则安装 `cargo-fuzz` 0.13.2，用 nightly 执行 `cargo fuzz build`，并对每个目标跑最多 15 秒。 |
| `mutants` | 默认关。打开后若没有 Cargo.toml，失败。否则 `cargo mutants --timeout 120`。 |

额外 inputs：`run-proptest`、`run-fuzz`、`run-mutants`，都是 boolean，默认 `false`。开关关闭时 job 仍会成功结束，并在日志里写明跳过原因，这样必需状态检查可以一直要求这几个名字。

### 3. 供应链 `supply-chain.yml`

| job | 做什么 |
| --- | --- |
| `deny` | `cargo deny check`。从 `working-directory` 向上找到调用方的 `deny.toml` 就用它；一直到仓库根都没有，就下载本仓库该提交的 [`deny.toml`](deny.toml)。 |
| `audit` | `cargo audit`。没有 `Cargo.lock` 就失败。 |
| `vet` | 见下文。 |

默认 [`deny.toml`](deny.toml) 只允许 crates.io，拒绝 git 依赖和通配版本，许可证使用白名单，`yanked = "deny"`。cargo-deny 0.22 里 `unmaintained` 和 `unsound` 的最严级别是 `all`，不是 `deny`，文件里按这个写。未发布的 workspace crate 也要声明 license。

#### 调用方没有 `supply-chain/` 时

cargo-vet 不会在缺少审计文件时自动给现有依赖发豁免。

- 工作目录或仓库根已有 `supply-chain/config.toml`：`cargo vet --locked` 使用调用方的策略。
- 没有这个目录，且 `Cargo.lock` 里没有第三方 `source`：写入临时空策略并真的跑 `cargo vet`。日志会说明这是空依赖图。临时文件不写回仓库。
- 没有这个目录，但锁文件里有第三方 crate：job 失败。日志要求提交 `supply-chain/`，并提示可以 `cargo vet init`、`cargo vet import mozilla`，再对剩余 crate `cargo vet certify` 或写下豁免理由。

有第三方依赖却还没做审计的 crate，接入后这一层会红，直到 `supply-chain/` 落地。这是故意的。

### 4. 接口与能力 `api.yml`

| job | 做什么 |
| --- | --- |
| `semver` | `cargo semver-checks --baseline-rev <rev>`。`semver-baseline` 默认 `auto`：pull request 用 base sha，否则用最新的 `v*` tag，再没有就用最新 tag。基线上不存在该 `Cargo.toml` 时视为新 crate，日志说明后成功退出。基线存在时，检查失败就是失败。 |
| `capabilities` | **占位**。运行 [`scripts/scan-capabilities.sh`](scripts/scan-capabilities.sh)，统计 `std::fs`、`std::net`、`std::process`、`std::env`、`std::thread`、`std::os` 以及对应的 `tokio::fs` / `tokio::net` / `tokio::process`。只打印报告，不失败。它不是能力边界，也不能代替 sandbox。 |

### 5. 防作弊 `protect.yml`

job `protected-paths` 不 checkout 调用方仓库，也不运行调用方文件。变更列表来自 compare API（`base...head`）。`Cargo.toml` 的 `[lints]` 是否变化，用 contents API 读取 base 和 head 的文件文本再比较，不执行其中的代码。检查脚本从定义该 job 的工作流提交（`job.workflow_sha`）下载。compare API 一次最多 300 个文件，达到上限就拒绝放行。

默认路径：

```text
.github/
contracts/
supply-chain/
clippy.toml
rustfmt.toml
deny.toml
rust-toolchain
rust-toolchain.toml
Cargo.toml[lints]
```

以 `/` 结尾的模式按仓库根前缀匹配。没有斜杠的名字匹配任意目录下的同名文件。`Cargo.toml[lints]` 只在某个 `Cargo.toml` 的 `[lints]` / `[lints.*]` 表发生变化时失败；改版本或依赖不会。input `protected-paths` 会替换默认列表，不会和默认值取并集。组织如果把本仓库的 `rust.yml` 配成 required workflow，用的是这里的默认值，调用方改不了。

调用方自己写 `uses` 时，可以传入别的列表。那次修改本身会改 `.github/`，在默认列表下会失败；如果有人同时把列表改空，必需状态检查仍会跑，但路径保护会被拿掉。要堵这个洞，用规则集的 required workflow，不要只依赖调用方仓库里的 YAML。不要把 required workflow 和调用方 `uses` 同时打开，否则整套 CI 会跑两遍。

本仓库例外：`github.repository` 等于工作流定义仓库，且 pull request 不是 fork（push 事件没有 head repo，同样视为同一仓库）时，命中项会写进日志，job 成功。fork 修改这些路径会失败。`burncloud/ci` 自己的变更改由组织规则集里更高的审批要求约束，见下文文档。否则这个仓库无法再合并对 `.github/` 的更新。

## 本仓库自测

[`tests/fixture`](tests/fixture) 是一个没有第三方依赖的库，带 `#![forbid(unsafe_code)]`、文档测试和单元测试。[`.github/workflows/ci.yml`](.github/workflows/ci.yml) 在 pull request 和 `main` 的 push 上用 `working-directory: tests/fixture` 调用 `rust.yml`。

`lint-workflows` job 另外跑 actionlint、shellcheck，以及对受保护路径、unsafe 检查、能力扫描、deny.toml 查找的正反例。反例必须得到非零退出码。

## 本地复现

需要 bash、jq、rustup、以及和上面版本一致的 cargo 子命令。在 crate 仓库根目录：

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features -- -D warnings -W clippy::pedantic
bash /path/to/burncloud-ci/scripts/check-unsafe.sh .
cargo test --workspace --all-targets
cargo test --workspace --doc
cargo deny --config deny.toml check
cargo audit
bash /path/to/burncloud-ci/scripts/run-cargo-vet.sh .
WORKING_DIRECTORY=. SEMVER_BASELINE=base BASE_SHA="$(git rev-parse origin/main)" \
  bash /path/to/burncloud-ci/scripts/run-semver-checks.sh
bash /path/to/burncloud-ci/scripts/scan-capabilities.sh .
```

proptest、fuzz、mutants 默认不跑。要在本地打开 fuzz，先准备 `fuzz/`，再 `cargo install --locked cargo-fuzz@0.13.2` 并用 nightly 执行 `cargo fuzz build`。

本仓库的工作流和脚本：

```bash
shellcheck scripts/*.sh
actionlint -shellcheck "$(command -v shellcheck)"
bash scripts/check-unsafe.sh tests/fixture
```

## 占位

只有能力扫描是占位：[`scripts/scan-capabilities.sh`](scripts/scan-capabilities.sh) 和 `capabilities` job 只输出报告。proptest、fuzz、mutants、semver、cargo-vet 都会真跑；前三个默认关闭，semver 在没有基线时跳过并写明原因，cargo-vet 在没有 `supply-chain/` 且存在第三方依赖时失败。

## 下一步

`burncloud/template` 放上上面的一行 `uses`，job id 用 `rust`。模板 crate 需要：

- 每个 lib.rs / main.rs 写上 `#![forbid(unsafe_code)]`
- 提交 `Cargo.lock`
- 在根目录放 `deny.toml`，或者接受本仓库的默认文件
- 一旦引入第三方 crate，就提交 `supply-chain/`，否则 `vet` 会失败
- 不要在调用方工作流里放宽 `protected-paths`

组织规则集先按 [docs/org-ruleset.md](docs/org-ruleset.md) 用 `evaluate` 导入，对过检查名后再改成 `active`。本文档不修改组织设置。
