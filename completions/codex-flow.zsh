#compdef codex-flow

_codex_flow() {
    local -a commands
    commands=(
        'status:Show installed version and effective FlowPilot policy'
        'update:Pull the checkout and refresh recommendations'
        'doctor:Verify installation, routing, and telemetry'
        'usage:Show deterministic FlowPilot usage summaries and history'
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
        _describe 'usage command' '(last list show stats summary)'
    elif (( CURRENT >= 4 )) && [[ "${words[2]}" == usage ]]; then
        case "${words[3]}" in
            last|show)
                _describe 'usage option' '(--json)' ;;
            list)
                _describe 'list option' '(--json --today -n --limit -p --project)' ;;
            stats|summary)
                _describe 'stats option' '(--json -d --days -p --project)' ;;
        esac
    fi
}

if (( $+functions[compdef] )); then
    compdef _codex_flow codex-flow
else
    autoload -Uz compinit
    compinit -i >/dev/null 2>&1 || true
    (( $+functions[compdef] )) && compdef _codex_flow codex-flow
fi
