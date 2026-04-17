import Foundation

/// Shell completion scripts for bash, zsh, and fish.
///
/// Scripts are pure shell — no sfsym runtime dep beyond one invocation of
/// `sfsym list` for dynamic symbol-name completion, which takes ~25 ms cold
/// and is fine for an interactive tab-press.
enum Completions {
    static func script(for shell: String) throws -> String {
        switch shell.lowercased() {
        case "bash": return bash
        case "zsh":  return zsh
        case "fish": return fish
        default:     throw CLIError.bad("unknown shell: \(shell) (expected bash, zsh, or fish)")
        }
    }

    // MARK: - zsh

    private static let zsh = #"""
#compdef sfsym
# zsh completion for sfsym — install via:
#   sfsym completions zsh > ~/.zsh/completions/_sfsym
#   # then add to .zshrc:
#   fpath=(~/.zsh/completions $fpath)
#   autoload -U compinit && compinit

_sfsym() {
    local -a subs
    subs=(
        'export:render a symbol to a file'
        'batch:bulk exports from stdin'
        'list:enumerate symbol names'
        'info:report layer metadata for a symbol'
        'modes:list supported rendering modes'
        'schema:machine-readable CLI schema (JSON)'
        'completions:generate shell completion script'
        'version:print version'
        'help:print help'
    )

    if (( CURRENT == 2 )); then
        _describe 'subcommand' subs
        return
    fi

    case "$words[2]" in
        export|info|modes)
            if (( CURRENT == 3 )); then
                local -a names
                names=(${(f)"$(sfsym list 2>/dev/null)"})
                _describe 'symbol' names
                return
            fi
            _arguments \
                '(-f --format)'{-f,--format}'[output format]:format:(pdf png svg)' \
                '--mode[rendering mode]:mode:(monochrome hierarchical palette multicolor)' \
                '--weight[font weight]:weight:(ultralight thin light regular medium semibold bold heavy black)' \
                '--scale[symbol scale]:scale:(small medium large)' \
                '--size[point size]:pt' \
                '--color[tint color (hex or systemXxx name)]:color' \
                '--palette[palette colors, comma-separated]:palette' \
                '(-o --out)'{-o,--out}'[output path (- = stdout)]:path:_files' \
                '--json[JSON output]'
            ;;
        list)
            _arguments \
                '--prefix[filter by prefix]:prefix' \
                '--limit[cap count]:n' \
                '--json[JSON output]'
            ;;
        batch)
            _arguments '--fail-fast[exit on first error]'
            ;;
        completions)
            if (( CURRENT == 3 )); then
                _values 'shell' bash zsh fish
            fi
            ;;
    esac
}

_sfsym "$@"
"""#

    // MARK: - bash

    private static let bash = #"""
# bash completion for sfsym — install via:
#   sfsym completions bash > /usr/local/etc/bash_completion.d/sfsym
#   # or source directly:
#   source <(sfsym completions bash)

_sfsym() {
    local cur prev sub
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    sub="${COMP_WORDS[1]}"

    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "export batch list info modes schema completions version help" -- "$cur") )
        return
    fi

    case "$prev" in
        -f|--format) COMPREPLY=( $(compgen -W "pdf png svg" -- "$cur") ); return ;;
        --mode)      COMPREPLY=( $(compgen -W "monochrome hierarchical palette multicolor" -- "$cur") ); return ;;
        --weight)    COMPREPLY=( $(compgen -W "ultralight thin light regular medium semibold bold heavy black" -- "$cur") ); return ;;
        --scale)     COMPREPLY=( $(compgen -W "small medium large" -- "$cur") ); return ;;
        -o|--out)    COMPREPLY=( $(compgen -f -- "$cur") ); return ;;
    esac

    case "$sub" in
        export|info|modes)
            if [[ $COMP_CWORD -eq 2 ]]; then
                local names
                names=$(sfsym list 2>/dev/null)
                COMPREPLY=( $(compgen -W "$names" -- "$cur") )
                return
            fi
            COMPREPLY=( $(compgen -W "-f --format --mode --weight --scale --size --color --palette -o --out --json" -- "$cur") )
            ;;
        list)
            COMPREPLY=( $(compgen -W "--prefix --limit --json" -- "$cur") )
            ;;
        batch)
            COMPREPLY=( $(compgen -W "--fail-fast" -- "$cur") )
            ;;
        completions)
            if [[ $COMP_CWORD -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") )
            fi
            ;;
    esac
}
complete -F _sfsym sfsym
"""#

    // MARK: - fish

    private static let fish = #"""
# fish completion for sfsym — install via:
#   sfsym completions fish > ~/.config/fish/completions/sfsym.fish

# Subcommands
complete -c sfsym -n '__fish_use_subcommand' -a export      -d 'render a symbol to a file'
complete -c sfsym -n '__fish_use_subcommand' -a batch       -d 'bulk exports from stdin'
complete -c sfsym -n '__fish_use_subcommand' -a list        -d 'enumerate symbol names'
complete -c sfsym -n '__fish_use_subcommand' -a info        -d 'report layer metadata'
complete -c sfsym -n '__fish_use_subcommand' -a modes       -d 'list supported rendering modes'
complete -c sfsym -n '__fish_use_subcommand' -a schema      -d 'machine-readable CLI schema (JSON)'
complete -c sfsym -n '__fish_use_subcommand' -a completions -d 'generate shell completion script'
complete -c sfsym -n '__fish_use_subcommand' -a version     -d 'print version'
complete -c sfsym -n '__fish_use_subcommand' -a help        -d 'print help'

# Dynamic symbol names for export / info / modes
complete -c sfsym -n '__fish_seen_subcommand_from export info modes; and not __fish_seen_subcommand_from (sfsym list)' \
    -a '(sfsym list)' -d 'symbol'

# Flags shared by export
complete -c sfsym -n '__fish_seen_subcommand_from export' -s f -l format -xa 'pdf png svg'       -d 'output format'
complete -c sfsym -n '__fish_seen_subcommand_from export'      -l mode   -xa 'monochrome hierarchical palette multicolor' -d 'rendering mode'
complete -c sfsym -n '__fish_seen_subcommand_from export'      -l weight -xa 'ultralight thin light regular medium semibold bold heavy black' -d 'font weight'
complete -c sfsym -n '__fish_seen_subcommand_from export'      -l scale  -xa 'small medium large' -d 'symbol scale'
complete -c sfsym -n '__fish_seen_subcommand_from export'      -l size   -x                       -d 'point size'
complete -c sfsym -n '__fish_seen_subcommand_from export'      -l color  -x                       -d 'tint color'
complete -c sfsym -n '__fish_seen_subcommand_from export'      -l palette -x                      -d 'palette colors (comma-separated)'
complete -c sfsym -n '__fish_seen_subcommand_from export' -s o -l out    -r                       -d 'output path'

# info / list / modes flags
complete -c sfsym -n '__fish_seen_subcommand_from info list modes' -l json -d 'JSON output'
complete -c sfsym -n '__fish_seen_subcommand_from list' -l prefix -x -d 'filter by prefix'
complete -c sfsym -n '__fish_seen_subcommand_from list' -l limit  -x -d 'cap count'

# batch
complete -c sfsym -n '__fish_seen_subcommand_from batch' -l fail-fast -d 'exit on first error'

# completions shell name
complete -c sfsym -n '__fish_seen_subcommand_from completions' -xa 'bash zsh fish'
"""#
}
