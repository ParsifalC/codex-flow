#compdef codex-flow

_codex_flow() {
    local -a commands
    commands=(
        'status:Show installed version and effective FlowPilot strategy'
        'strategy:Inspect or configure the multi-strategy runtime'
        'language:Show or set UI language (auto/zh/en)'
        'update:Pull the checkout and refresh recommendations'
        'doctor:Verify installation, strategy runtime, and telemetry'
        'overlay:Manage the native macOS floating widget'
        'usage:Show deterministic FlowPilot usage summaries and history'
        'telemetry:Telemetry collection, inspection, and historical repair'
        'benchmark-local:Run the built-in benchmark through the local Codex login'
        'benchmark-corpus:Materialize the built-in corpus'
        'benchmark:Run a reproducible benchmark manifest'
        'benchmark-analyze:Analyze benchmark JSONL results'
        'uninstall:Remove codex-flow-managed files'
        'help:Show command help'
    )
    if (( CURRENT == 2 )); then
        _describe 'command' commands
    elif (( CURRENT == 3 )) && [[ "${words[2]}" == strategy ]]; then
        _describe 'strategy command' '(show profiles enabled enable disable set routing plan)'
    elif (( CURRENT == 4 )) && [[ "${words[2]}" == strategy && "${words[3]}" == set ]]; then
        _describe 'strategy profile' '(efficient balanced quality speed)'
    elif (( CURRENT == 4 )) && [[ "${words[2]}" == strategy && "${words[3]}" == routing ]]; then
        _describe 'routing mode' '(adaptive direct delegate)'
    elif (( CURRENT >= 4 )) && [[ "${words[2]}" == strategy && "${words[3]}" == plan ]]; then
        _describe 'plan option' '(--profile --routing --review --fanout --complexity --uncertainty --risk --scope --parallelism --write-conflict --exploration-need --verification-cost --iteration-intensity --writable-workstreams --quality-intent --quota-pressure --max-threads --max-repairs)'
    elif (( CURRENT == 3 )) && [[ "${words[2]}" == language ]]; then
        _describe 'language' '(auto zh en)'
    elif (( CURRENT == 3 )) && [[ "${words[2]}" == benchmark-local || "${words[2]}" == benchmark-corpus ]]; then
        _describe 'profile' '(quick full)'
    elif (( CURRENT == 3 )) && [[ "${words[2]}" == usage || "${words[2]}" == telemetry ]]; then
        _describe 'usage command' '(last list show stats summary repair)'
    elif (( CURRENT >= 4 )) && [[ "${words[2]}" == usage || "${words[2]}" == telemetry ]]; then
        case "${words[3]}" in
            last|show) _describe 'usage option' '(--json)' ;;
            list) _describe 'list option' '(--json --today -n --limit -p --project)' ;;
            stats|summary) _describe 'stats option' '(--json -d --days -p --project)' ;;
            repair) _describe 'repair option' '(--dry-run --json)' ;;
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
