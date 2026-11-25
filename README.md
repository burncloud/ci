# burncloud/ci

BurnCloud 各 Rust crate 仓库共用的 GitHub Actions。规则只改这里。现在走 GitHub 免费套餐：清单仓库保持公开，用 `uses` 钉 40 位完整 SHA 或 `vX.Y.Z` 标签，再配单仓库规则集和 CODEOWNERS。禁止 `v1` 这类浮动标签，也禁止分支名。组织级 required workflow 需要 Team，写在 [docs/org-ruleset.md](docs/org-ruleset.md)，升级之后再用。调用方仓库里的 YAML 挡不住改检查：PR 可以改 `protected-paths`、换掉 `uses`，或写同名空 job。改工作流靠 CODEOWNERS 审批。`rustburn` 负责写代码，是 owner，紧急时走仓库管理员的 pull request bypass。`ivories`（GitHub id `12606587`）负责审批，是 Code Owner。

调用方放这一份。工作流不要命名为 `Rust`，否则并发组会撞名。模板用 `name: CI`：

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
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
  rust:
    uses: burncloud/ci/.github/workflows/rust.yml@<40 位 SHA 或 vX.Y.Z>
    with:
      run-proptest: false
      run-fuzz: false
      run-mutants: false
```

升级到 Team 并启用组织级 required workflow 之后，再删掉这份 `uses` job，否则会和注入的 `rust.yml` 各跑一遍。免费套餐下留着这个 job，它就是清单仓库的 CI。

仓库设置里两处要改：

- Actions → General → Fork pull request workflows：选 Require approval for all outside collaborators。外部贡献者的 PR 在批准之前不跑 Actions。
- Actions → General → Workflow permissions：关闭 Allow GitHub Actions to create and approve pull requests。

插件仓库要额外检查 wasm 目标时再传 `targets`。这一项不放进上面的通用模板。只检查库和二进制，不编译测试：

```yaml
jobs:
  rust:
    uses: burncloud/ci/.github/workflows/rust.yml@<40 位 SHA 或 vX.Y.Z>
    with:
      targets: wasm32-wasip2
```

仓库根要提交 `rust-toolchain.toml`，不要依赖浮动的 `stable`。工作流先读这个文件（仓库根优先，其次是 `working-directory`），没有才用 `toolchain` 输入。文件本身在默认受保护路径里。

`working-directory` 默认是仓库根。一个仓库里有多个 crate 时，不要共用一个叫 `rust` 的 job，见 [docs/org-ruleset.md](docs/org-ruleset.md)。并发组是 `rust-${{ github.workflow }}-${{ PR 号或 ref }}-${{ inputs.concurrency-key }}`。直接触发时工作流名是 `Rust`；`uses` 调用时是调用方工作流的名字。调用方的工作流不要命名为 `Rust`，否则和直接触发或 required workflow 注入的组名相同，两边会互相取消。同一次工作流里如果调用两次，看到的工作流名相同，每次要传不同的 `concurrency-key`，否则后一次会取消整次运行。直接由 `pull_request` 触发时 key 留空，同一 PR 的新提交仍会取消旧运行。

## 版本怎么固定

调用方 `uses` 只允许两种 ref：40 位完整 SHA，或 `vX.Y.Z`。禁止 `v1` 这类浮动标签，也禁止分支名。SHA 接受大小写十六进制，`v` 只小写。正则是 `^([0-9a-fA-F]{40}|v[0-9]+\.[0-9]+\.[0-9]+)$`，实现在 [`scripts/check-pinned-ref.sh`](scripts/check-pinned-ref.sh)。

发布时在目标提交上打 `vX.Y.Z`。这个标签打出之后不要移动。调用方要拿后续修复，就改自己的 ref。

| 引用 | 结果 |
| --- | --- |
| `@<40 位 SHA>` | 固定在那一次提交。 |
| `@vX.Y.Z` | 固定在这个三位版本标签上。标签不要移动。 |
| `@v1`、分支名 | 禁止。 |

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
| `clippy` | `cargo clippy --locked --workspace --all-targets --all-features -- -D warnings -W clippy::pedantic -D clippy::allow_attributes_without_reason` |
| `unsafe` | 读每个 crate 的 `Cargo.toml`。必须有 `[lints.rust] unsafe_code = "forbid"`（或继承 workspace 的同名设置），由编译器在 `cargo clippy` / `cargo test` 时强制。需要 unsafe 的包把包名写进受保护的 `unsafe-crates.txt`。不再扫描源码文本。 |

### 2. 测试 `test.yml`

| job | 做什么 |
| --- | --- |
| `cargo-test` | `cargo test --locked --workspace --all-targets --all-features` |
| `doc-test` | `cargo test --locked --workspace --doc` |
| `cargo-doc` | `RUSTDOCFLAGS=-D warnings cargo doc --locked --workspace --no-deps --all-features` |
| `msrv` | 按每个 crate 的 `rust-version` 跑 `cargo check --locked`。都没写就跳过并说明。 |
| `extra-targets` | `targets` 输入为空则跳过。插件仓库可传 `wasm32-wasip2`。只检查库和二进制，不编译测试。 |
| `wit` | 没有 `wit/`（或 `wit-dir`）就跳过。有目录则对整个目录跑一次 `wasm-tools component wit`。若有基线提交，再用 `git diff` 报告接口差异；没有成熟的 WIT 兼容性工具，差异不因此失败。 |
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
- 没有目录，但每个第三方依赖都是 `git+https://github.com/burncloud/<仓库>`，仓库名只有一段且不是 `.` 或 `..`，后面只允许 `.git`、`?rev=` / `?tag=` 和 `#` 十六进制 sha：按统一策略写入豁免后再跑。`../`、百分号编码、别的主机或 `burncloud-evil` 这种 owner 都不会被信任。crates.io 上的同名包也不会。
- 还有其他第三方 crate：失败。请 `cargo vet init` 并提交 `supply-chain/`，或 `cargo vet import mozilla` 后再 certify。

### 4. 接口与能力 `api.yml`

| job | 做什么 |
| --- | --- |
| `semver` | `cargo semver-checks --baseline-rev`。`auto` 在 pull request 上用 base sha，否则用最新 tag。基线上没有该清单时视为新 crate，说明后跳过。 |
| `capabilities` | 只打印能力报告，不阻断。没有 `reason` 的 `#[allow]` 由 lint 层的 clippy 拒绝。 |

能力路线图：

1. 现在：报告 `std::fs`、`std::net`、`std::process`、`std::env`、`std::thread`、`std::os` 以及对应的 tokio 路径。报告不阻断。不写理由的 `allow` 放在 clippy 里拒绝。
2. 下一步：把报告和一份受保护的能力清单对比，未声明的 `std::fs` / `net` / `process` 直接失败。
3. 再下一步：用 capability crate 或 sandbox 表达能力，而不是只靠文本扫描。

### 5. 防作弊 `protect.yml`

不 checkout 调用方仓库，不执行调用方代码。变更列表来自 compare API。`Cargo.toml` 的受保护表用 contents API 读文本再比较。

默认路径只写在 [`scripts/check-protected-paths.sh`](scripts/check-protected-paths.sh)。required workflow 不会传入 `protected-paths`，输入为空时脚本使用这份默认列表。非空输入会整份替换默认列表，不是追加。当前默认值包括 `.github/`、`.cargo/`、`vendor/`、`contracts/`、`supply-chain/`、clippy/rustfmt/deny 配置、`rust-toolchain`、`rust-toolchain.toml`、`unsafe-crates.txt`、删除仓库根 `Cargo.toml`，以及用 TOML 解析器比较的 `lints`、`workspace.lints`、`patch`、`replace`。`build.rs` 不在默认列表里；要保护它就传一整份新的路径列表。

豁免只在 `github.repository` 和 `job.workflow_repository` 都是 `burncloud/ci` 时生效。把工作流复制到别的仓库再用相对路径引用，不会再被当成源仓库。fork 上的 `github.repository` 仍是 base 仓库；如果 workflow 也来自 `burncloud/ci`，这次豁免仍会生效。跨仓库的真实行为在打 `vX.Y.Z` 之前还要用一个外部 crate 仓库核对。调用方到时候也只能引用这个标签或 40 位 SHA。

`merge_group` 用事件里的 `base_sha` 和 `head_sha` 比较。新分支 push 的 `before` 如果是全 0，改为和默认分支比较。

## 本仓库自测

[`tests/fixture`](tests/fixture) 带 proptest、`fuzz/`、`supply-chain/`，以及 `[lints.rust] unsafe_code = "forbid"`。`ci.yml` 用 `uses` 加 `with` 调用 `rust.yml` 两次：一次打开 proptest、fuzz、mutants，并把 semver 基线设为 `9236264ec7b8a7b22c622fd0d0ad69c495b15348`；一次把 `targets` 设为 `wasm32-wasip2`、三个开关关闭。`rust.yml` 自己的 `pull_request` 触发仍会再跑一遍默认输入。只有 `burncloud/ci` 在没有根 `Cargo.toml` 时会回退到 `tests/fixture`。

## 本地复现

需要 bash、jq、python3，以及和 `rust-toolchain.toml` 一致的工具链。

```bash
cargo fmt --all --check
cargo clippy --locked --workspace --all-targets --all-features -- -D warnings -W clippy::pedantic -D clippy::allow_attributes_without_reason
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
python3 scripts/check-rulesets.py
bash scripts/check-pinned-ref.sh v1.0.0
```

## 下一步

`burncloud/template` 提交 `rust-toolchain.toml`、`Cargo.lock`，并按上面的并发配置引用 40 位 SHA 或 `vX.Y.Z`。有非 burncloud 的第三方依赖时要提交 `supply-chain/`。清单仓库保持公开，按 [docs/org-ruleset.md](docs/org-ruleset.md) 配单仓库规则集和 CODEOWNERS。`uses` 调用的检查名已经在 template 上看到，是 `rust / lint / fmt` 这种三段式。组织级 required workflow 仍是升级到 Team 之后的选项，注入后的检查名还没核对。
