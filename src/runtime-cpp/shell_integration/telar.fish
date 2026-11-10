# telar shell integration for fish. telar put this directory first in XDG_DATA_DIRS, so
# fish reads this file from vendor_conf.d before the user's configuration. Restore
# XDG_DATA_DIRS first, so programs started from fish see the user's own.
if set -q TELAR_FISH_XDG_DATA_DIRS
    set -gx XDG_DATA_DIRS $TELAR_FISH_XDG_DATA_DIRS
    set -e TELAR_FISH_XDG_DATA_DIRS
else
    set -e XDG_DATA_DIRS
end

set -g __telar_token "$TELAR_SHELL_TOKEN"
set -g __telar_ssh "$TELAR_SHELL_SSH"
set -e TELAR_SHELL_TOKEN TELAR_SHELL_SSH
if not status is-interactive; or not string match -qr '^[0-9a-f]{32}$' -- $__telar_token
    set -e __telar_token
    return
end

# `ssh` starts remote login shells with the integration too, unless the user defined one.
if test -n "$__telar_ssh" -a -r "$__telar_ssh"; and not functions -q ssh
    function ssh --wraps ssh
        TELAR_SHELL_TOKEN=$__telar_token /bin/sh $__telar_ssh $argv
    end
end

# Marks prompts and commands with OSC 133, signed with the pane's token so telar trusts
# them and ignores the ones a program prints.
function __telar_preexec --on-event fish_preexec
    printf '\e]133;C;telar=%s\a' $__telar_token
end

function __telar_postexec --on-event fish_postexec
    printf '\e]133;D;%s;telar=%s\a' $status $__telar_token
end

# Its commands no PATH directory holds. An alias (a function `alias` made) or an abbreviation
# that stands for plain words goes as name=words, %-encoded, so completion follows it.
function __telar_names
    for name in (functions -n)
        string match -qr '^_|[^[:alnum:]._+:@-]' -- $name; and continue
        set -l details (functions --details --verbose $name)
        set -l words (string replace -rf '^alias [^=]+=' '' -- $details[5])
        __telar_name $name "$words"
    end
    for line in (abbr --show)
        set -l parts (string match -r -- '^abbr .*-- (\S+) (.*)$' $line)
        test (count $parts) -eq 3; or continue
        string match -qr '^_|[^[:alnum:]._+:@-]' -- $parts[2]; and continue
        __telar_name $parts[2] (string unescape -- $parts[3])
    end
end

function __telar_name --argument-names name words
    if test -n "$words"; and not string match -qr '[^[:alnum:]._/:@%+,= -]' -- $words
        echo $name=(string replace -a ' ' '%20' -- (string replace -a '%' '%25' -- $words))
    else
        echo $name
    end
end

function __telar_prompt --on-event fish_prompt
    printf '\e]133;A;telar=%s\a' $__telar_token
    # The working directory (OSC 7), so telar knows where the next command runs.
    printf '\e]7;file://%s%s\a' $hostname (string replace -a '%' '%25' -- $PWD)
    # The PATH, when it changed, so completion finds the commands this shell runs.
    set -l path (string join : $PATH)
    if test "$path" != "$__telar_path"
        set -g __telar_path $path
        printf '\e]6973;telar=%s;path=%s\a' $__telar_token (string replace -a ';' '%3B' -- (string replace -a '%' '%25' -- $path))
    end
    # Its functions and abbreviations, when their count changed: commands no PATH directory
    # holds, which telar's editor must not mark missing.
    set -l names (functions -n) (abbr --list)
    if test (count $names) != "$__telar_names"
        set -g __telar_names (count $names)
        printf '\e]6973;telar=%s;names=%s\a' $__telar_token (string join ' ' -- (__telar_names))
    end
    # Wrap the prompt on the first one, once the user's configuration defined it.
    if not set -q __telar_wrapped; and functions -q fish_prompt
        set -g __telar_wrapped
        functions -c fish_prompt __telar_user_prompt
        function fish_prompt
            __telar_user_prompt
            printf '\e]133;B;telar=%s\a' $__telar_token
        end
    end
end
