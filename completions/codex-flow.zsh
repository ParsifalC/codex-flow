#compdef codex-flow

_codex_flow() {
    local -a commands
    commands=(
        'status:Show installed version and effective policy'
        'update:Pull the checkout and refresh recommendations'
        'doctor:Verify installation and routing configuration'
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
    fi
}

# compdef is available after compinit. Initialize it when this file is sourced
# early from .zshrc so both initialization orders register the completion.
if (( $+functions[compdef] )); then
    compdef _codex_flow codex-flow
else
    autoload -Uz compinit
    compinit -i >/dev/null 2>&1 || true
    (( $+functions[compdef] )) && compdef _codex_flow codex-flow
fi
