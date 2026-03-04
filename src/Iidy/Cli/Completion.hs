{- | Shell completion scripts for iidy-hs.

Static completion script generation for bash, zsh, and fish shells.
-}
module Iidy.Cli.Completion (
    bashCompletionScript,
    zshCompletionScript,
    fishCompletionScript,
) where

bashCompletionScript :: String
bashCompletionScript =
    unlines
        [ "_iidy_hs()"
        , "{"
        , "    local CMDLINE"
        , "    local IFS=$'\\n'"
        , "    CMDLINE=(--bash-completion-index $COMP_CWORD)"
        , ""
        , "    for arg in ${COMP_WORDS[@]}; do"
        , "        CMDLINE=(${CMDLINE[@]} --bash-completion-word $arg)"
        , "    done"
        , ""
        , "    COMPREPLY=( $(iidy-hs \"${CMDLINE[@]}\") )"
        , "}"
        , ""
        , "complete -o filenames -F _iidy_hs iidy-hs"
        ]

zshCompletionScript :: String
zshCompletionScript =
    unlines
        [ "#compdef iidy-hs"
        , ""
        , "_iidy_hs()"
        , "{"
        , "    local CMDLINE"
        , "    local IFS=$'\\n'"
        , "    CMDLINE=(--bash-completion-index $((CURRENT-1)))"
        , ""
        , "    for arg in ${words[@]}; do"
        , "        CMDLINE=(${CMDLINE[@]} --bash-completion-word $arg)"
        , "    done"
        , ""
        , "    local completions"
        , "    completions=($(iidy-hs \"${CMDLINE[@]}\"))"
        , ""
        , "    compadd -a completions"
        , "}"
        , ""
        , "compdef _iidy_hs iidy-hs"
        ]

fishCompletionScript :: String
fishCompletionScript =
    unlines
        [ "function _iidy_hs"
        , "    set -l cl (commandline --tokenize --current-process)"
        , "    set -l cn (count $cl)"
        , "    set -l tmpline --bash-completion-index $cn"
        , "    for arg in $cl"
        , "        set tmpline $tmpline --bash-completion-word $arg"
        , "    end"
        , "    for opt in (iidy-hs $tmpline)"
        , "        echo -E \"$opt\""
        , "    end"
        , "end"
        , ""
        , "complete -c iidy-hs -f -a '(_iidy_hs)'"
        ]
