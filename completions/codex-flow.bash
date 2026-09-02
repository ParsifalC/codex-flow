# bash completion for codex-flow
_codex_flow_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local commands="status strategy language update doctor overlay usage benchmark-local benchmark-corpus benchmark benchmark-analyze uninstall help"
    if [[ "${COMP_CWORD}" -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    elif [[ "${COMP_CWORD}" -eq 2 && "${COMP_WORDS[1]}" == "strategy" ]]; then
        COMPREPLY=( $(compgen -W "show profiles set routing plan" -- "$cur") )
    elif [[ "${COMP_CWORD}" -eq 3 && "${COMP_WORDS[1]}" == "strategy" && "${COMP_WORDS[2]}" == "set" ]]; then
        COMPREPLY=( $(compgen -W "efficient balanced quality speed" -- "$cur") )
    elif [[ "${COMP_CWORD}" -eq 3 && "${COMP_WORDS[1]}" == "strategy" && "${COMP_WORDS[2]}" == "routing" ]]; then
        COMPREPLY=( $(compgen -W "adaptive direct delegate" -- "$cur") )
    elif [[ "${COMP_CWORD}" -ge 3 && "${COMP_WORDS[1]}" == "strategy" && "${COMP_WORDS[2]}" == "plan" ]]; then
        COMPREPLY=( $(compgen -W "--profile --routing --review --fanout --complexity --uncertainty --risk --scope --parallelism --write-conflict --exploration-need --verification-cost --iteration-intensity --writable-workstreams --quality-intent --quota-pressure --max-threads --max-repairs" -- "$cur") )
    elif [[ "${COMP_CWORD}" -eq 2 && "${COMP_WORDS[1]}" == "language" ]]; then
        COMPREPLY=( $(compgen -W "auto zh en" -- "$cur") )
    elif [[ "${COMP_CWORD}" -eq 2 && ( "${COMP_WORDS[1]}" == "benchmark-local" || "${COMP_WORDS[1]}" == "benchmark-corpus" ) ]]; then
        COMPREPLY=( $(compgen -W "quick full" -- "$cur") )
    elif [[ "${COMP_CWORD}" -eq 2 && "${COMP_WORDS[1]}" == "usage" ]]; then
        COMPREPLY=( $(compgen -W "last list show stats summary" -- "$cur") )
    elif [[ "${COMP_WORDS[1]}" == "usage" ]]; then
        case "${COMP_WORDS[2]}" in
            last) COMPREPLY=( $(compgen -W "--json" -- "$cur") ) ;;
            list) COMPREPLY=( $(compgen -W "--json --today -n --limit -p --project" -- "$cur") ) ;;
            show) COMPREPLY=( $(compgen -W "--json" -- "$cur") ) ;;
            stats|summary) COMPREPLY=( $(compgen -W "--json -d --days -p --project" -- "$cur") ) ;;
            *) COMPREPLY=() ;;
        esac
    else
        COMPREPLY=()
    fi
}
complete -F _codex_flow_completion codex-flow
