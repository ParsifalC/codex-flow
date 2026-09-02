# Cloud Benchmarking on GitHub Actions

<div align="center">

[ 简体中文 ](benchmark-actions.md) | [ English ](benchmark-actions.en.md)

</div>

The optional GitHub Actions workflow automates the built-in 30-run `quick` benchmark profile in the cloud. It is not scheduled and will never trigger on `push` or `pull_request`; it requires manual dispatch with an explicit confirmation phrase.

---

## One-Time Setup

Add a repository Actions secret:

```text
OPENAI_API_KEY
```

Use an API project/key with an intentionally bounded budget and only the model access required for the benchmark.

---

## Dispatching a Benchmark

1. Open the **Actions** tab on GitHub.
2. Select the **benchmark quick** workflow and click **Run workflow**.
3. Fill in the parameters:
   - `confirm`: `RUN QUICK 30`
   - `codex_npm_version`: `latest` (or a pinned npm version)

---

## Benchmark Composition

```text
6 tasks × 5 strategies × 1 repetition = 30 runs

1. Luna direct (high)
2. Terra direct (high)
3. Sol direct (high)
4. Flow fixed (Sol parent high + Luna worker high)
5. Flow adaptive (routine high, complex xhigh, critical max)
```

---

## Generated Artifacts

The workflow records and uploads all execution logs, metrics, and markdown reports for 30 days:
- `manifest.json`, `results.jsonl`, `analysis.json`
- `report.md` (rendered directly into the GitHub Actions Job Summary)
