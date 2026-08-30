# Paid quick benchmark on GitHub Actions

`codex-flow` v0.7 adds a manually dispatched GitHub Actions workflow for the built-in **quick** benchmark only.

It is intentionally not scheduled and it cannot run from `push` or `pull_request`. The workflow requires an exact confirmation phrase before any Codex model call is made.

## One-time setup

Create a repository Actions secret named:

```text
OPENAI_API_KEY
```

The workflow passes this value only through the process environment. Current Codex CLI authentication code supports `OPENAI_API_KEY`; no interactive login or committed auth file is required.

Use an API project/key with an intentionally bounded budget and only the model access needed for the benchmark.

## Start a run

In GitHub Actions, open **benchmark quick** and choose **Run workflow**.

Inputs:

```text
confirm:            RUN QUICK 18
codex_npm_version:  latest   # or a pinned npm version
```

The confirmation must match exactly. The workflow validates the key is present before installing/running Codex.

For comparisons across dates, pin `codex_npm_version` instead of using `latest`. Every artifact records both the requested npm version and the actual `codex --version` output.

## What runs

The workflow materializes the deterministic `quick` corpus:

```text
6 tasks × 3 configurations × 1 repetition = 18 runs

Luna / high
Terra / xhigh
Sol / high
```

Every run starts from the frozen corpus commit, uses the external verifier, and includes bounded repairs. The runner is invoked with `--fail-fast-infrastructure`: if Codex exits non-zero before reporting any token usage (for example bad credentials or an unavailable CLI/model), the batch stops instead of repeating the same infrastructure failure across the remaining configurations.

## Artifacts

The workflow uploads a 30-day artifact containing the files that exist at the end of the run:

```text
materialize.json
plan.json
manifest.json
results.jsonl
analysis.json
report.md
prices.json
codex-version.txt
codex-npm-version-requested.txt
codex-flow-commit.txt
```

A partial/failing run still uploads available diagnostics. If at least one result row exists, the workflow also renders the report into the GitHub Actions job summary.

`report.md` contains overall pass rate, infrastructure failures, repair count, token totals, estimated cost, per-model/effort results, and advisory class routing.

## Cost and promotion boundaries

This workflow spends real API/model quota. It therefore has all of the following safeguards:

- manual `workflow_dispatch` only
- exact paid-run confirmation phrase
- quick profile only (18 runs)
- no automatic full/90-run workflow
- missing API key fails before model execution
- infrastructure failures can stop the batch immediately
- routing output remains advisory (`auto_apply = false`)

The 90-run `full` corpus remains available through local/manual `codex-flow benchmark` execution, but is deliberately not exposed as a GitHub Actions button until quick results justify the additional spend.
