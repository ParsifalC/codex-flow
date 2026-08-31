#compdef codex-flow

_codex_flow() {
    local -a commands
    commands=(
        'status:Show installed version and effective FlowPilot policy'
        'update:Pull the checkout and refresh recommendations'
        'doctor:Verify installation, routing, and telemetry'
        'usage:Show deterministic FlowPilot usage summaries'
        'benchmark-local:Run the built-in benchmark through the local Codex login'
        'benchmark-corpus:Materialize the built-in corpus'
        'benchmark:Run a reproducible benchmark manifest'
        'benchmark-analyze:Analyze benchmark JSONL results'
        'uninstall:Remove codex-flow-managed files'
        'help:Show command help'
    )
    if (( CURRENT == 2 )); then
        _describe 'command' commands
    elif (( CURRENT == 3 )) && [[ "${words[2]}" == benchmark-local || "${words[2]}" == benchmark-corpus ]]; then
        _describe 'profile' '(quick full)'
    elif (( CURRENT == 3 )) && [[ "${words[2]}" == usage ]]; then
        _describe 'usage command' '(last)'
    elif (( CURRENT == 4 )) && [[ "${words[2]}" == usage && "${words[3]}" == last ]]; then
        _describe 'usage option' '(--json)'
    fi
}

if (( $+functions[compdef] )); then
    compdef _codex_flow codex-flow
else
    autoload -Uz compinit
    compinit -i >/dev/null 2>&1 || true
    (( $+functions[compdef] )) && compdef _codex_flow codex-flow
fi
