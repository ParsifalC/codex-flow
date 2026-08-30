# codex-flow

**简体中文** | [English](README.en.md)

为 Codex 提供低摩擦、成本感知的多 Agent 开发工作流默认策略。

**让高能力模型负责决策，让更经济的 Worker 负责执行；只有任务确实需要时，才提高推理强度。**

`codex-flow` 按模型能力和任务复杂度路由，不永久绑定某个模型名称，也不固定使用某个 reasoning level。

## 默认策略

```text
SMALL      -> 合格的 Parent 直接完成
ROUTINE    -> Parent 规划(high) -> Worker 实施(high) -> Parent 验收(high)
COMPLEX    -> Parent 规划(high/xhigh) -> Worker 实施(high/xhigh) -> Parent 验收(high/xhigh)
CRITICAL   -> 质量优先；只有确有必要时才升级到 xhigh/max
```

Parent 是否合格由策略决定，而不是由模型名称决定。默认优先使用当前最新的高能力模型，Parent 最低 reasoning 为 `high`，具体模型下限可配置；Worker 独立选择当前更具成本效率、适合编码的模型。因此 `gpt-5.6-sol/xhigh` 可以是一个组合，但绝不是硬性要求。

## 当前任务显式路由

用户可以在当前任务中明确控制是否使用子 Agent，不需要修改任何持久配置：

```text
direct     -> 当前任务不使用子 Agent
delegate   -> 当前任务明确优先交给子 Agent 执行
adaptive   -> 当前任务使用 codex-flow 默认自动路由
```

也支持意图明确的自然语言，例如：

```text
不要使用子 agent，直接完成
这次直接做
跳过 worker
不用 delegation

使用子 agent
这次交给 worker 实现

按默认策略
自动决定是否使用子 agent
```

当前任务中的显式路由指令优先于 codex-flow 默认策略和持久配置，但**只对当前任务生效**，不会写回用户配置。如果同一任务里出现互相冲突的明确指令，以最后一条明确指令为准。

`direct` 只关闭 delegation，不会关闭任务分类、reasoning 自适应、验证、验收标准、有限修复和 review。流程只是从：

```text
Parent -> Worker -> Parent review
```

变成：

```text
Parent -> implementation -> self-review
```

## 安装

### macOS / Linux

```bash
git clone git@github.com:ParsifalC/codex-flow.git
cd codex-flow
bash install.sh
```

### Windows PowerShell

```powershell
git clone git@github.com:ParsifalC/codex-flow.git
cd codex-flow
.\install.ps1
```

管理命令默认安装到 `~/.local/bin`。如果当前默认 shell 是 Bash 或 zsh，安装器还会向对应的 rc 文件写入一个带明确标记、可重复执行的托管块。该托管块会自动把 CLI 目录加入 `PATH`，并注册 `codex-flow` 子命令补全，包括 `benchmark-local quick|full` 和 `benchmark-corpus quick|full`。安装完成后，安装器会明确提示执行 `source ~/.zshrc`（Bash 为 `source ~/.bashrc`）立即更新当前终端，或者打开一个新终端。Codex 本身仍需重启，之后正常使用即可，不需要每次手动调用特殊命令或 Prompt。

Shell 选择优先读取 `CODEX_FLOW_SHELL`，否则使用 `SHELL` 的 basename。`CODEX_FLOW_SHELL_CONFIG_DIR` 可将托管的 `.bashrc`、登录 profile 或 `.zshrc` 放到指定配置目录；无法识别 shell 时，安装器仍会输出手动添加 `PATH` 的提示。

## 常用管理命令

```bash
codex-flow status
codex-flow doctor
codex-flow update
codex-flow benchmark-local quick
codex-flow uninstall
```

`update` 会 fast-forward 原始 checkout，保留用户明确指定的模型/推理配置，重新执行安装，并且只对 `auto` 配置重新解析当前版本推荐值。

## 默认自适应配置

直接安装且不提供任何环境变量覆盖时，会生成类似下面的 `~/.codex/codex-flow.toml`：

```toml
schema_version = 2

[parent]
model_policy = "latest-capable"
min_model = "auto"
min_reasoning_effort = "high"
reasoning_policy = "adaptive"
routine_effort = "high"
complex_effort = "xhigh"
critical_effort = "max"

[worker]
model_policy = "latest-efficient"
model = "auto"
resolved_model = "gpt-5.6-luna"
min_reasoning_effort = "high"
reasoning_policy = "adaptive"
routine_effort = "high"
complex_effort = "xhigh"
critical_effort = "max"

[runtime]
max_concurrent_threads = 4
max_repair_cycles = 2
```

`model = "auto"` 会跟随 codex-flow 当前版本的推荐；如果用户明确指定具体模型，则更新时继续保持该 pin。Parent 不会因为推荐元数据而被硬编码成某个固定 Sol 版本。

安装器同时会维护 Codex 的 `[agents]` 运行时兜底，例如当前默认：

```toml
[agents]
enabled = true
max_concurrent_threads_per_session = 4
default_subagent_model = "gpt-5.6-luna"
default_subagent_reasoning_effort = "high"
```

它不会强制修改用户当前选择的主模型。

## 推理强度选择

默认目标是使用“足够完成任务的最低合格推理强度”，而不是无条件拉满：

| 任务类型 | Parent | Worker |
| --- | --- | --- |
| SMALL | `high` 或当前合格强度 | 不使用 Worker |
| ROUTINE | `high` | `high` |
| COMPLEX | `high` / `xhigh` | `high` / `xhigh` |
| CRITICAL | `xhigh` / `max` | 仅质量优先时使用 `xhigh` / `max` |

`max` 永远不是通用默认值。只有任务风险、复杂度或者较低强度的实际失败证据足以证明有必要时才升级。

## 内置 Benchmark

项目提供一个确定性的六任务 Benchmark corpus，按 2 routine / 2 complex / 2 critical 平衡分层。它同时测量 direct 模型能力、固定强度 Flow 增量，以及自适应推理强度的价值。覆盖：

- 局部 Bug 修复
- 配置优先级
- 多文件兼容性重构
- 配置迁移
- 可恢复且幂等的数据迁移
- 具有权限与目录持久化语义的原子状态写入

当前 profiles：

```text
quick
  6 tasks × 5 strategies × 1 repetition = 30 runs
  Luna direct/high
  Terra direct/high
  Sol direct/high
  Flow fixed: Sol parent/high + Luna worker/high
  Flow adaptive: routine=high, complex=xhigh, critical=max

full
  6 tasks × 5 strategies × 3 repetitions = 90 runs
  与 quick 使用相同五组策略
```

三组 direct 与固定 Flow 全部使用 `high`，确保模型与策略结论不会混入 reasoning 差异；自适应 Flow 单列分析。Flow 由 runner 显式执行 `Sol 只读规划 → Luna 实现 → 外部 verifier → Sol 只读复核 → Luna 定向修复`，并分别记录 parent/worker usage。每个任务都会生成确定性的 seed commit，并使用位于可写任务仓库之外的外部 verifier。

`quick` 每个类别只有 2 个样本，用于烟雾观察；`full` 每策略每类别有 6 个样本，才满足默认正式证据门槛。

## 推荐真实 Benchmark：本地 Codex 登录态

本地已经认证的 Codex session 是当前默认的真实 Benchmark 路径。如果本机 Codex CLI 已经通过 ChatGPT 或其他受支持的本地方式登录，**不需要 API Key**。

运行：

```bash
codex-flow update
codex-flow benchmark-local quick
```

该命令会自动完成：

```text
检查 git / Python / Codex
显示 Codex CLI 版本
        ↓
生成冻结的 quick corpus
        ↓
dry-run 验证 30 个计划执行
        ↓
显示 quota / token 提示
        ↓
要求输入确认：
RUN QUICK 30
        ↓
执行 30 次真实 Codex 策略任务
        ↓
认证/CLI 等零 usage 基础设施失败时立即停止
        ↓
分析结果
        ↓
生成 Markdown 报告
```

默认会在 `benchmark/results/` 下生成带时间戳的结果：

```text
quick-<timestamp>.jsonl
quick-<timestamp>.analysis.json
quick-<timestamp>.report.md
quick-<timestamp>.meta.json
```

metadata 会记录 Codex CLI 版本、codex-flow commit、本地认证执行模式、manifest 路径以及结果/报告路径。

第一次 `quick` 建议按**最多约 1500 万总 token**作为保守预算上限。Flow 的规划/复核以及 repair 会增加 usage；实际消耗可能明显不同。

### 成本含义

如果 Benchmark 使用 ChatGPT/Codex 套餐登录态执行，报告中的美元数字全部是：

> **API-equivalent reference cost（API 等价参考成本）**

它使用固定 API 价格快照把不同模型放到统一尺度上比较，**不代表 ChatGPT 套餐实际产生了对应美元账单**。

套餐用户更应该关注：

- 任务通过率
- 首轮通过率
- repair cycles
- parent review cycles
- input / cached input / output tokens
- 总 token 效率
- wall time
- API 等价参考成本

## 底层 Benchmark 命令

如果需要单独控制每一步，仍然可以使用：

```bash
codex-flow benchmark-corpus quick

codex-flow benchmark \
  --manifest .codex-flow-benchmark/manifest.json \
  --output benchmark/results/quick-001.jsonl \
  --fail-fast-infrastructure

codex-flow benchmark-analyze \
  --results benchmark/results/quick-001.jsonl \
  --prices benchmark/prices/gpt-5.6-2026-08-30.json \
  --json
```

Analyzer 会分别输出 Sol 同强度能力证据、固定 Flow 相对 Sol/Luna 的增量证据、自适应 Flow 相对固定 Flow 的证据，再在质量门槛后比较总参考成本。Flow 成本包含 parent 与 worker。Benchmark 结论保持 advisory；`policy/benchmark.toml` 默认 `auto_apply = false`。

## 可选：API Key + GitHub Actions Benchmark

`.github/workflows/benchmark-quick.yml` 仍然保留，作为拥有 OpenAI API Key 用户的可选无头执行方式，但它不再是默认 Benchmark 路径。

该 workflow：

- 仅支持手动 `workflow_dispatch`
- 需要 repository secret `OPENAI_API_KEY`
- 需要精确确认 `RUN QUICK 30`
- 只开放 30-run `quick` profile
- 正常 CI 永远不会自动调用付费模型
- 会上传原始结果、analysis、report 和相关 metadata

## 自动模型推荐

`scripts/check-recommendation.py` 和 `.github/workflows/model-recommendation.yml` 会保守地检查 OpenAI 官方模型文档，并通过可 review 的 PR 维护 release recommendation。

设计原则是：

- Parent 始终由能力策略决定，而不是推荐值硬 pin
- Worker 的 `auto` 推荐可以随着新一代高性价比模型更新
- 用户明确 pin 的模型不会被 update 偷偷覆盖
- 无法可靠确认模型能力或价格时 fail closed

## 测量边界

当前 Codex JSONL 能提供 input / cached input / output usage，但不能稳定提供独立 reasoning-token 字段，也不能稳定返回 provider 最终实际使用的 model identifier。因此 Benchmark 记录请求的 model/effort，以及 Codex 实际能够可靠提供的 usage 字段。

完整方法说明见 `docs/benchmark.md`。
GitHub Actions 可选路径说明见 `docs/benchmark-actions.md`。

## 安装时覆盖项

```text
CODEX_FLOW_PARENT_MODEL_POLICY    默认: latest-capable
CODEX_FLOW_PARENT_MIN_MODEL       默认: auto
CODEX_FLOW_PARENT_MIN_EFFORT      默认: high
CODEX_FLOW_WORKER_MODEL_POLICY    默认: latest-efficient
CODEX_FLOW_WORKER_MODEL           默认: auto
CODEX_FLOW_WORKER_MIN_EFFORT      默认: high
CODEX_FLOW_MAX_THREADS            默认: 4
CODEX_FLOW_MAX_REPAIR_CYCLES      默认: 2
CODEX_FLOW_BIN_DIR                默认: ~/.local/bin
CODEX_FLOW_SHELL                  默认: SHELL 的 basename（自动配置 Bash/zsh）
CODEX_FLOW_SHELL_CONFIG_DIR       默认: HOME
```

## CI

普通 CI **不会调用真实付费模型**。目前主要验证：

- Shell / Python / PowerShell 语法
- 模型推荐 fixture
- quality-first Benchmark 分析
- 报告生成
- runner 隔离、repair、token 聚合与基础设施 fail-fast
- 确定性 corpus 生成
- `direct` / `delegate` / `adaptive` 显式路由规则是否正确安装
- Unix / Windows 安装与更新流程

## 当前状态

Private preview，版本 `0.8.2`。

本地认证 Benchmark 是默认真实数据采集路径；`direct`、`delegate`、`adaptive` 是显式且非持久的当前任务覆盖；模型推荐变更需要 review；Benchmark routing 保持 advisory；真实 Benchmark 必须由用户明确触发；用户明确 pin 的配置始终拥有最高持久配置优先级。
