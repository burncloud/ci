# burncloud/ci

BurnCloud 各 Rust crate 仓库共用的 GitHub Actions。规则只改这里。组织规则集应把本仓库的 `rust.yml` 配成 required workflow，并钉死到不可变 tag 或提交 SHA。调用方仓库里的 YAML 不能当成安全边界：它可以改 `protected-paths`、换掉 `uses`，或写同名空 job。

调用方仍然可以放这一份，方便人读，并在 required workflow 还没启用时先跑起来：

```yaml
name: CI
on:
  pull_request:
  merge_group:
  push:
    branches: [main]
permissions:
  contents: read
concurrency:
  group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
jobs:
  rust:
    uses: burncloud/ci/.github/workflows/rust.yml@<不可变 tag 或 SHA>
```

仓库根要提交 `rust-toolchain.toml`，不要依赖浮动的 `stable`。工作流先读这个文件（仓库根优先，其次是 `working-directory`），没有才用 `toolchain` 输入。文件本身在默认受保护路径里。

`working-directory` 默认是仓库根。一个仓库里有多个 crate 时，不要共用一个叫 `rust` 的 job，见 [docs/org-ruleset.md](docs/org-ruleset.md)。

## 版本怎么固定

发布时在目标提交上打不可变的 `vX.Y.Z`。已经发出的补丁 tag 不要移动。`v1` 可以指到当前主版本，方便人读，但 required workflow 不要钉 `v1`，要钉 `vX.Y.Z` 或 40 位 SHA。

| 引用 | 行为 |
| --- | --- |
| `@v1` | 维护者移动标签后，下一次运行就带上这一主版本里的修复。标签会变。 |
| `@vX.Y.Z` 或 `@<SHA>` | 不会跟着变。修复要调用方或规则集自己改 ref。 |

本仓库的 action 都钉完整提交 SHA，注释里写发行标签。`dtolnay/rust-toolchain` 的 `v1` 会移动，所以钉 2026-11-15 的 `df2a88e9fe4098bad09cb42c3dec7187f15861fc`。`Swatinem/rust-cache` 钉 `d1527c8f67ef9af357290475d4af4b0fab8f12e0`（v2.9.3），并且只在 `refs/heads/main` 上 `save-if`。cargo 子命令用 `taiki-e/install-action` v2.90.8（`fe3acb53a98b62c772db35de75ce0e4595e7ca8c`），写上工具版本。清单里有的工具设 `fallback: none`。cargo-fuzz 不在这份清单里，用同一 action 的 `cargo-binstall` 回退安装预编译的 `cargo-fuzz@0.13.2`，不再 `cargo install` 从源码编译。

当前工具版本：cargo-deny 0.22.0、cargo-audit 0.23.0、cargo-vet 0.10.3、cargo-semver-checks 0.51.0、cargo-mutants 27.1.0、wasm-tools 1.263.0、cargo-fuzz 0.13.2。

脚本和默认 `deny.toml` 用 `actions/checkout` 取工作流定义仓库的 `job.workflow_sha`，放到 `.burncloud-ci`，不再从 `raw.githubusercontent.com` 下载。

## 五层

汇总工作流是 [`.github/workflows/rust.yml`](.github/workflows/rust.yml)。它有 `workflow_call`、`pull_request` 和 `merge_group`。权限是 `contents: read`。`cargo` 命令带 `--locked`。同一 PR 的新提交会取消旧运行。

直接被 `pull_request` 触发、且仓库根没有 `Cargo.toml` 时，会改用 `tests/fixture`。这只为了本仓库自测。crate 仓库应把清单放在根目录，或通过 `working-directory` 指进去。

### 1. 格式与静态检查 `lint.yml`

| job | 做什么 |
| --- | --- |
| `fmt` | `cargo fmt --all --check` |
| `clippy` | `cargo clippy --locked --workspace --all-targets --all-features -- -D warnings -W clippy::pedantic` |
| `unsafe` | 每个 lib/bin 根文件必须有 `#![forbid(unsafe_code)]`。再在去掉注释和字符串之后搜索 `unsafe` 整词。`unsafe-allow.txt` 可以按文件或 `路径:行号` 放行，这个文件在默认受保护路径里。 |

### 2. 测试 `test.yml`

| job | 做什么 |
| --- | --- |
| `cargo-test` | `cargo test --locked --workspace --all-targets --all-features` |
| `doc-test` | `cargo test --locked --workspace --doc` |
| `cargo-doc` | `RUSTDOCFLAGS=-D warnings cargo doc --locked --workspace --no-deps --all-features` |
| `msrv` | 按每个 crate 的 `rust-version` 跑 `cargo check --locked`。都没写就跳过并说明。 |
| `extra-targets` | `targets` 输入为空则跳过。插件仓库可传 `wasm32-wasip2`。 |
| `wit` | 没有 `wit/`（或 `wit-dir`）就跳过。有目录则用 `wasm-tools component wit` 校验每个 `.wit`。 |
| `proptest` | 默认关。打开后没有 `proptest` 依赖则失败；有则 `PROPTEST_CASES=256`。 |
| `fuzz` | 默认关。打开后没有 `fuzz/Cargo.toml` 或 target 则失败。有则用 `nightly-2026-11-20` 构建并每个目标最多跑 15 秒。`cargo-fuzz` 0.13.2 的 build 子命令没有 `--locked`，所以先 `cargo metadata --locked`。Linux 预编译包是 musl，构建时显式指定 `x86_64-unknown-linux-gnu`，否则会去编 musl 目标。 |
| `mutants` | 默认关。pull request 上用 `git diff --relative` 加 `--in-diff`；其他事件检查全部突变。 |

### 3. 供应链 `supply-chain.yml`

| job | 做什么 |
| --- | --- |
| `deny` | 从 `working-directory` 向上找调用方的 `deny.toml`。没有则用本仓库 checkout 里的默认文件。 |
| `audit` | `cargo audit`。没有 `Cargo.lock` 就失败。 |
| `vet` | 见下文。 |

默认 [`deny.toml`](deny.toml) 只允许 crates.io，另外用 `[sources.allow-org] github = ["burncloud"]` 允许本组织的 git 依赖。`required-git-spec = "tag"` 表示 git 依赖至少要写 tag；rev 比 tag 更具体，同样允许。只写 branch，或什么说明符都不写，会失败。通配版本拒绝。许可证是白名单。`yanked = "deny"`。cargo-deny 0.22 里 `unmaintained` / `unsound` 的最严级别是 `all`。

#### 没有 `supply-chain/` 时

- 已有 `supply-chain/config.toml`：`cargo vet --locked` 用调用方的策略。
- 没有目录，也没有第三方依赖：临时空策略，真跑 `cargo vet`。
- 没有目录，但第三方依赖全是 `burncloud-*` 或 `github.com/burncloud/` 的 git 依赖：按统一策略写入 `safe-to-deploy` 和 `safe-to-run` 豁免后再跑。
- 还有其他第三方 crate：失败。请 `cargo vet init` 并提交 `supply-chain/`，或 `cargo vet import mozilla` 后再 certify。

### 4. 接口与能力 `api.yml`

| job | 做什么 |
| --- | --- |
| `semver` | `cargo semver-checks --baseline-rev`。`auto` 在 pull request 上用 base sha，否则用最新 tag。基线上没有该清单时视为新 crate，说明后跳过。 |
| `capabilities` | 先打印能力报告，再跑 `cargo clippy --locked --workspace --all-targets --all-features -- -D clippy::allow_attributes_without_reason`。没有 `reason` 的 `#[allow]` 会失败。 |

能力路线图：

1. 现在：报告 `std::fs`、`std::net`、`std::process`、`std::env`、`std::thread`、`std::os` 以及对应的 tokio 路径，并且拒绝不写理由的 `allow`。报告本身不阻断。
2. 下一步：把报告和一份受保护的能力清单对比，未声明的 `std::fs` / `net` / `process` 直接失败。
3. 再下一步：用 capability crate 或 sandbox 表达能力，而不是只靠文本扫描。

### 5. 防作弊 `protect.yml`

不 checkout 调用方仓库，不执行调用方代码。变更列表来自 compare API。`Cargo.toml` 的受保护表用 contents API 读文本再比较。

默认路径只写在 [`scripts/check-protected-paths.sh`](scripts/check-protected-paths.sh)。`protect.yml` 和 `rust.yml` 的输入留空时用这份列表，空字符串不会把保护拿掉。当前默认值包括 `.github/`、`.cargo/`、`vendor/`、`contracts/`、`supply-chain/`、clippy/rustfmt/deny 配置、`rust-toolchain`、`rust-toolchain.toml`、`unsafe-allow.txt`，以及 `Cargo.toml` 里的 `[lints]`、`[workspace.lints]`、`[patch]`、`[replace]`。`build.rs` 先不放进默认列表；个别仓库可以在输入里追加。

豁免只在 `github.repository` 和 `job.workflow_repository` 都是 `burncloud/ci` 时生效。把工作流复制到别的仓库再用相对路径引用，不会再被当成源仓库。fork 上的 `github.repository` 仍是 base 仓库；如果 workflow 也来自 `burncloud/ci`，这次豁免仍会生效。跨仓库的真实行为在打不可变 tag 之前还要用一个外部 crate 仓库核对。

`merge_group` 用事件里的 `base_sha` 和 `head_sha` 比较。新分支 push 的 `before` 如果是全 0，改为和默认分支比较。

## 本仓库自测

[`tests/fixture`](tests/fixture) 带 proptest、`fuzz/` 和 `supply-chain/`。[`.github/workflows/ci.yml`](.github/workflows/ci.yml) 用 `run-proptest`、`run-fuzz`、`run-mutants` 都为 true 调用汇总工作流，并把 semver 基线钉在已经包含该 crate 的 `19c15f8ba75d81dcc51c89af43b51a386b76f2f3`。`rust.yml` 自己的 `pull_request` 触发会再跑一遍默认开关。

## 本地复现

需要 bash、jq、python3，以及和 `rust-toolchain.toml` 一致的工具链。

```bash
cargo fmt --all --check
cargo clippy --locked --workspace --all-targets --all-features -- -D warnings -W clippy::pedantic
cargo clippy --locked --workspace --all-targets --all-features -- -D clippy::allow_attributes_without_reason
bash scripts/check-unsafe.sh tests/fixture
cargo test --locked --workspace --all-targets --all-features
cargo test --locked --workspace --doc
RUSTDOCFLAGS='-D warnings' cargo doc --locked --workspace --no-deps --all-features
cargo deny --config deny.toml --manifest-path tests/fixture/Cargo.toml check
cargo audit
bash scripts/run-cargo-vet.sh tests/fixture
bash scripts/scan-capabilities.sh tests/fixture
shellcheck scripts/*.sh
actionlint -shellcheck "$(command -v shellcheck)"
```

## 下一步

`burncloud/template` 提交 `rust-toolchain.toml`、`Cargo.lock`，并按上面的并发配置引用不可变 ref。有非 burncloud 的第三方依赖时要提交 `supply-chain/`。组织规则集先按 [docs/org-ruleset.md](docs/org-ruleset.md) 以 `evaluate` 导入。required workflow 的两段式检查名还没用外部 crate 仓库核对，打 `v1` 之前视为待验证。
