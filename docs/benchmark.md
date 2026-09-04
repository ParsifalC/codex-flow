# 基准测试驱动的路由评估 (Benchmark)

<div align="center">

[ 简体中文 ](benchmark.md) | [ English ](benchmark.en.md)

</div>

基准测试套件旨在严谨回答以下三个独立问题，且绝不混淆各自的实证数据：

1. **同等推理强度下**，Sol 是否直接超越 Luna 和 Terra？
2. **固定强度协同策略** 是否能在降低总成本的同时，保持 Sol 级别的高质量并超越 Luna 直连？
3. **分级自适应推理策略** 是否能以可控的成本提升换取关键任务质量的实质跃升？

测试结果仅供参考。实际模型运行必须积累足够的证据后才会考虑调整路由策略，且 `policy/benchmark.toml` 默认保持 `auto_apply = false`。

内置 benchmark 的 `reasoning_effort` 是 runner 直接传给 `codex exec` 的实验配置；它不会经过 FlowPilot planner，因此不能证明 `ExecutionPlan.reasoning_rollout` 的 proposed/selected 值在真实 delegated Worker 上实际生效。rollout 决策应使用运行时记录的 observed effort、完成/截尾样本与 p50/p95 数据另行验证。

---

## 五种预注册评估策略

`quick`（快速模式）与 `full`（完整模式）采用完全相同的策略对照矩阵：

| 策略 ID | 执行方式 | 推理强度配置 |
| :--- | :--- | :--- |
| `luna-direct` | Luna 独立实现与修复 | `high` |
| `terra-direct` | Terra 独立实现与修复 | `high` |
| `sol-direct` | Sol 独立实现与修复 | `high` |
| `codex-flow-high` | Sol 父级规划 + Luna 子任务执行 | 双方固定 `high` |
| `codex-flow-adaptive` | Sol 父级规划 + Luna 子任务执行 | 常规 `high` · 复杂 `xhigh` · 核心 `max` |

前四种策略构成严格受控的**同等推理强度对照组**。`codex-flow-adaptive` 策略仅用于同 `codex-flow-high` 对比自适应收益。

---

## 平衡工程语料库 (Corpus)

语料库包含 6 个确定性工程任务，严格平衡分布于三类复杂度：

| 任务名称 | 复杂度分类 | 核心考察焦点 |
| :--- | :--- | :--- |
| `routine-query-normalization` | 常规 (Routine) | 本地化 Unicode 与空白字符处理 |
| `routine-env-precedence` | 常规 (Routine) | 配置加载优先级与边界分支 |
| `complex-renew-provider-refactor` | 复杂 (Complex) | 模块化 Provider 注册表重构、校验与向下兼容 |
| `complex-config-migration` | 复杂 (Complex) | 深拷贝安全的新旧配置迁移与幂等性保证 |
| `critical-resumable-migration` | 关键 (Critical) | 带审计日志、校验可恢复的幂等数据迁移 |
| `critical-atomic-state-write` | 关键 (Critical) | 原子化文件持久替换、权限控制、软链安全与异常回滚 |

无需调用大模型即可本地初始化语料库：

```bash
codex-flow benchmark-corpus quick
```

测试配置文件见 `benchmark/profiles.json`：

```text
quick: 6 任务 × 5 策略 × 1 次重复 = 30 轮运行
full:  6 任务 × 5 策略 × 3 次重复 = 90 轮运行
```

---

## 实证检验规则 (Evidence Tests)

使用 GPT-5.6 官方不可变价格快照执行分析：

```bash
codex-flow benchmark-analyze \
  --results benchmark/results/quick-001.jsonl \
  --prices benchmark/prices/gpt-5.6-2026-08-30.json \
  --json
```

### 1. Sol 综合能力判定
在每一复杂度级别下，Sol/high 与最强的 Luna/high 或 Terra/high 对比。Sol 必须在最终通过率上不低于对照组，并在首次通过率或修复轮次上有显著提升。

### 2. 固定流协同优势判定 (Flow Advantage)
`codex-flow-high` 必须同时满足：
- 最终交付质量保持在 Sol/high 的非劣效区间内；
- 父子总折算成本相比 Sol/high 降低指定幅度；
- 相比 Luna/high 直连，在最终质量、首通率或修复轮次上有实质改进。

### 3. 自适应推理收益判定 (Adaptive Value)
`codex-flow-adaptive` 仅与 `codex-flow-high` 比较，必须在控制成本涨幅上限的前提下，显著提升复杂和关键任务的交付率。
