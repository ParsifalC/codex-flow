# bash completion for codex-flow
_codex_flow_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local commands="status update doctor usage benchmark-local benchmark-corpus benchmark benchmark-analyze uninstall help"
    if [[ "${COMP_CWORD}" -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    elif [[ "${COMP_CWORD}" -eq 2 && ( "${COMP_WORDS[1]}" == "benchmark-local" || "${COMP_WORDS[1]}" == "benchmark-corpus" ) ]]; then
        COMPREPLY=( $(compgen -W "quick full" -- "$cur") )
    elif [[ "${COMP_CWORD}" -eq 2 && "${COMP_WORDS[1]}" == "usage" ]]; then
        COMPREPLY=( $(compgen -W "last" -- "$cur") )
    elif [[ "${COMP_CWORD}" -eq 3 && "${COMP_WORDS[1]}" == "usage" && "${COMP_WORDS[2]}" == "last" ]]; then
        COMPREPLY=( $(compgen -W "--json" -- "$cur") )
    else
        COMPREPLY=()
    fi
}

complete -F _codex_flow_completion codex-flow
