#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(python3 "$ROOT_DIR/scripts/analyze-benchmark.py" \
  --results "$ROOT_DIR/tests/fixtures/benchmark-results.jsonl" \
  --prices "$ROOT_DIR/tests/fixtures/benchmark-prices.json" \
  --policy "$ROOT_DIR/policy/benchmark.toml" \
  --json)"
python3 - "$out" <<'PY'
import json, sys
r = json.loads(sys.argv[1])["recommendations"]
assert r["routine"]["model"] == "gpt-5.6-luna", r
assert r["routine"]["reasoning_effort"] == "high", r
assert r["complex"]["model"] == "gpt-5.6-terra", r
assert r["complex"]["reasoning_effort"] == "xhigh", r
assert r["critical"]["model"] == "gpt-5.6-terra", r
assert r["critical"]["reasoning_effort"] == "max", r
PY

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$TMP/strategy-results.jsonl" <<'PY'
import json,sys
path=sys.argv[1]
models={'luna-direct':'gpt-5.6-luna','terra-direct':'gpt-5.6-terra','sol-direct':'gpt-5.6-sol'}
rows=[]
def direct(strategy,rep,passed,first,repairs):
    model=models[strategy]
    usage={'role':'direct','model':model,'reasoning_effort':'high','calls':repairs+1,'input_tokens':100000,'cached_input_tokens':20000,'output_tokens':20000}
    return {'schema_version':2,'task_id':f'c{rep}','task_class':'complex','strategy_id':strategy,'strategy':'direct','reasoning_policy':'fixed','model':model,'reasoning_effort':'high','worker_model':None,'worker_reasoning_effort':None,'passed':passed,'first_passed':first,'input_tokens':100000,'cached_input_tokens':20000,'output_tokens':20000,'model_usage':[usage],'repair_cycles':repairs,'review_cycles':0,'wall_time_seconds':100.0,'source_commit':'a'*40,'repetition':rep,'codex_exit_code':0,'verification_excerpt':'','diagnostic_excerpt':''}
def flow(strategy,rep,first,adaptive=False):
    effort='xhigh' if adaptive else 'high'
    parent={'role':'parent','model':'gpt-5.6-sol','reasoning_effort':effort,'calls':2,'input_tokens':12000 if adaptive else 10000,'cached_input_tokens':2000,'output_tokens':1000}
    worker={'role':'worker','model':'gpt-5.6-luna','reasoning_effort':effort,'calls':1 if first else 2,'input_tokens':85000 if adaptive else 80000,'cached_input_tokens':20000,'output_tokens':16000}
    total={k:parent[k]+worker[k] for k in ('input_tokens','cached_input_tokens','output_tokens')}
    return {'schema_version':2,'task_id':f'c{rep}','task_class':'complex','strategy_id':strategy,'strategy':'flow','reasoning_policy':'adaptive' if adaptive else 'fixed','model':'gpt-5.6-sol','reasoning_effort':effort,'worker_model':'gpt-5.6-luna','worker_reasoning_effort':effort,'passed':True,'first_passed':first,**total,'model_usage':[parent,worker],'repair_cycles':0 if first else 1,'review_cycles':1 if first else 2,'wall_time_seconds':130.0 if adaptive else 120.0,'source_commit':'a'*40,'repetition':rep,'codex_exit_code':0,'verification_excerpt':'','diagnostic_excerpt':''}
for rep in range(1,4):
    rows.append(direct('luna-direct',rep,rep<3,rep<3,0 if rep<3 else 2))
    rows.append(direct('terra-direct',rep,rep<3,rep<3,0 if rep<3 else 2))
    rows.append(direct('sol-direct',rep,True,True,0))
    rows.append(flow('codex-flow-high',rep,rep<3))
    rows.append(flow('codex-flow-adaptive',rep,True,adaptive=True))
with open(path,'w') as f:
    for row in rows: f.write(json.dumps(row)+'\n')
PY

strategy_out="$(python3 "$ROOT_DIR/scripts/analyze-benchmark.py" \
  --results "$TMP/strategy-results.jsonl" \
  --prices "$ROOT_DIR/benchmark/prices/gpt-5.6-2026-08-30.json" \
  --policy "$ROOT_DIR/policy/benchmark.toml" \
  --json)"
python3 - "$strategy_out" <<'PY'
import json,sys
r=json.loads(sys.argv[1])
sol=r['sol_capability_evidence']['complex']
flow=r['flow_advantage_evidence']['complex']
adaptive=r['adaptive_reasoning_evidence']['complex']
assert sol['evidence_sufficient'] and sol['advantage_demonstrated'],sol
assert sol['paired_samples'] and sol['controlled_reasoning_effort']=='high',sol
assert flow['quality_noninferior_to_sol'] and flow['cost_reduction_vs_sol'] >= .30,flow
assert flow['paired_samples'] and flow['controlled_reasoning_effort']=='high',flow
assert flow['worker_quality_gain'] and flow['advantage_demonstrated'],flow
assert adaptive['paired_samples'] and adaptive['reasoning_policies_match'],adaptive
assert adaptive['quality_gain'] and adaptive['value_demonstrated'],adaptive
PY

python3 - "$TMP/strategy-results.jsonl" "$TMP/invalid-control-results.jsonl" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]
for row in rows:
    if row['strategy_id']=='codex-flow-high':
        row['worker_reasoning_effort']='xhigh'
        for usage in row['model_usage']:
            if usage['role']=='worker': usage['reasoning_effort']='xhigh'
    if row['strategy_id']=='codex-flow-adaptive' and row['repetition']==3:
        row['task_id']='unpaired-task'
with open(sys.argv[2],'w') as sink:
    for row in rows: sink.write(json.dumps(row)+'\n')
PY
invalid_out="$(python3 "$ROOT_DIR/scripts/analyze-benchmark.py" \
  --results "$TMP/invalid-control-results.jsonl" \
  --prices "$ROOT_DIR/benchmark/prices/gpt-5.6-2026-08-30.json" \
  --policy "$ROOT_DIR/policy/benchmark.toml" \
  --json)"
python3 - "$invalid_out" <<'PY'
import json,sys
r=json.loads(sys.argv[1])
flow=r['flow_advantage_evidence']['complex']
adaptive=r['adaptive_reasoning_evidence']['complex']
assert not flow['evidence_sufficient'] and not flow['advantage_demonstrated'],flow
assert flow['controlled_reasoning_effort'] is None,flow
assert not adaptive['paired_samples'],adaptive
assert not adaptive['evidence_sufficient'] and not adaptive['value_demonstrated'],adaptive
PY
printf 'benchmark test passed\n'
