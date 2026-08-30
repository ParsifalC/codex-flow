# Paid quick benchmark on GitHub Actions

The optional GitHub Actions workflow runs only the built-in 30-run `quick` profile. It is not scheduled and cannot run from `push` or `pull_request`; a user must manually dispatch it and provide the exact confirmation phrase before any model call.

## One-time setup

Create a repository Actions secret named:

```text
OPENAI_API_KEY
```

Use an API project/key with an intentionally bounded budget and only the model access needed for the benchmark. For comparisons across dates, pin the Codex npm version instead of using `latest`.

## Start a run

Open the **benchmark quick** workflow and choose **Run workflow**:

```text
confirm:            RUN QUICK 30
codex_npm_version:  latest   # or a pinned npm version
```

The key and exact confirmation are validated before execution.

## What runs

```text
6 tasks × 5 strategies × 1 repetition = 30 runs

Luna direct / high
Terra direct / high
Sol direct / high
Flow fixed / Sol parent high + Luna worker high
Flow adaptive / routine high, complex xhigh, critical max
```

The first four strategies are the controlled same-effort comparison. Adaptive flow is analyzed separately against fixed-high flow. Every run starts from a frozen corpus commit, uses an external verifier, and includes bounded repairs. Flow usage includes both parent and worker.

`--fail-fast-infrastructure` stops the batch when Codex exits non-zero before reporting usage, avoiding repeated spend attempts after credentials, CLI, or model-access failures.

## Artifacts

The workflow uploads available files for 30 days:

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

A partial run still uploads diagnostics. When results exist, the Markdown report is also written to the Actions job summary. It includes final/first-pass rates, repairs, parent reviews, tokens, wall time, mixed-model API-equivalent reference cost, and the three evidence comparisons.

## Safety and interpretation

The workflow spends real API/model quota and therefore has these boundaries:

- manual `workflow_dispatch` only;
- exact `RUN QUICK 30` confirmation;
- quick profile only, with 30 runs;
- no automatic full/90-run workflow;
- missing API key fails before execution;
- infrastructure failures can stop the batch immediately;
- results remain advisory and never rewrite routing automatically.

`quick` has two samples per class and strategy, below the default formal evidence minimum of three. Use it for smoke/observational evidence. The 90-run `full` profile has six samples per class and strategy and remains available only through explicit local/manual execution.
