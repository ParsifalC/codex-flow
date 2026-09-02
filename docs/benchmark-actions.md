# GitHub Actions 云端基准评测

<div align="center">

[ 简体中文 ](benchmark-actions.md) | [ English ](benchmark-actions.en.md)

</div>

本项目包含可选的 GitHub Actions 工作流，用于在云端自动化执行内置的 30 轮 `quick` 基准评测。该工作流绝不在 `push` 或 `pull_request` 时自动触发，必须由管理员在 GitHub 网页上手动派发并输入严格的确认口令。

---

## 初始准备

在 GitHub 仓库中配置 Actions Secret：

```text
OPENAI_API_KEY
```

建议使用设置了消费预算上限并仅开放所需模型权限的独立 API 密钥。

---

## 触发运行流程

1. 进入 GitHub 仓库的 **Actions** 选项卡；
2. 选择 **benchmark quick** 工作流并点击 **Run workflow**；
3. 输入必填参数：
   - `confirm`: `RUN QUICK 30`
   - `codex_npm_version`: `latest`（或指定 npm 版本号）

---

## 评测矩阵构成

```text
6 任务 × 5 策略 × 1 次重复 = 30 轮运行

1. Luna direct (high)
2. Terra direct (high)
3. Sol direct (high)
4. Flow fixed (Sol parent high + Luna worker high)
5. Flow adaptive (routine high, complex xhigh, critical max)
```

---

## 产物与报告汇总

工作流运行完毕后，将自动归档全部评测产物（保留 30 天）：
- `manifest.json`, `results.jsonl`, `analysis.json`
- `report.md`（自动渲染至 GitHub Actions Job Summary 汇总看板）
