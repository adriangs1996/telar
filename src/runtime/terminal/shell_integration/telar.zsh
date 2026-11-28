# telar shell integration for zsh, loaded once before the user's .zshrc.
# It marks prompts and commands with OSC 133 and signs every mark with the pane's
# token, so telar trusts these marks and ignores the ones a program prints.
(( ${+_telar_token} )) && builtin return 0
builtin typeset -g _telar_token=${TELAR_SHELL_TOKEN-} _telar_ssh=${TELAR_SHELL_SSH-} _telar_ssh_control=${TELAR_SHELL_SSH_CONTROL-} _telar_mode=
# telar's editor stands in for the prompt: the shell prints only its marks.
[[ ${TELAR_PROMPT_MODE-} == telar ]] && _telar_mode=telar
builtin unset TELAR_SHELL_TOKEN TELAR_SHELL_SSH TELAR_SHELL_SSH_CONTROL TELAR_PROMPT_MODE
if [[ ${#_telar_token} -ne 32 || $_telar_token == *[^0-9a-f]* ]]; then
  builtin unset _telar_token
  builtin return 0
fi

builtin typeset -gi _telar_status=0
builtin typeset -g _telar_path _telar_names _telar_ran
builtin typeset -g _telar_input_mark=$'%{\e]133;B;telar='$_telar_token$'\a%}'
# Spelling correction asks before preexec: its question starts the command, so the answer
# reaches zsh instead of telar's editor.
builtin typeset -g _telar_start_mark=$'%{\e]133;C;telar='$_telar_token$'\a%}'
# Where a command's output ends. zsh prints PROMPT_EOL_MARK (PROMPT_SP) once a command ends, before
# any precmd hook and so before the command's end mark: what it prints is the shell's, not the
# command's output, and this mark at its front says so.
builtin typeset -g _telar_end_mark=$'%{\e]6973;telar='$_telar_token$';ended\a%}'

# Keys typed while telar's editor was not up (before the first prompt, or while a slow precmd
# ran) reach this line editor, where telar's editor hides them. telar types CSI 6973 ~, a
# sequence no terminal sends for a key (6973 is telar's own number, as in its OSC 6973 reports),
# before each command its editor runs: this widget reports the line to telar, %-encoded, so its
# editor shows it, and clears it, so the command runs alone. It leaves vi's command mode for
# insert, where the command telar pastes is typed.
_telar_flush() {
  if [[ -n $BUFFER ]]; then
    builtin local encoded=$BUFFER char
    if [[ $BUFFER == *[%\;[:cntrl:]]* ]]; then
      encoded=
      for char in ${(s::)BUFFER}; do
        [[ $char == [%\;[:cntrl:]] ]] && char=%${(l:2::0:)$(( [##16] #char ))}
        encoded+=$char
      done
    fi
    builtin print -rn -- $'\e]6973;telar='$_telar_token';typeahead='$encoded$'\a'
  fi
  BUFFER= CURSOR=0
  [[ $KEYMAP == vicmd ]] && builtin zle -K viins
  # Output a background job printed while zsh waited here, without the job report after which
  # zsh draws its prompt again (NO_NOTIFY), sits where the prompt was: drawn again, the prompt
  # starts below it, as the command telar's editor runs does. Only telar's mode, whose prompt is
  # a mark alone, costs nothing to draw.
  [[ -n $_telar_mode ]] && builtin zle reset-prompt
  builtin return 0
}
builtin zle -N _telar_flush

# First precmd hook, so it reads the command's status before other hooks change it. zsh
# reports the background jobs that ended (with NO_NOTIFY, every one) between the command's end
# mark and the precmd hooks: the report ends here, before what the hooks print.
_telar_save_status() {
  _telar_status=$?
  builtin print -rn -- $'\e]6973;telar='$_telar_token$';jobs=0\a'
}

# Last precmd hook, so the input mark survives themes that rebuild PS1 in their hooks.
_telar_prompt() {
  # No command ran since the last prompt: an empty line, Ctrl-C, or a line the spelling
  # correction's question gave back to the line editor (e) or dropped (a) after its C mark. An
  # input mark first says the line editor has the line again, so telar ends no command.
  [[ -n $_telar_ran ]] || builtin print -rn -- $'\e]133;B;telar='$_telar_token$'\a'
  _telar_ran=
  builtin print -rn -- $'\e]133;D;'$_telar_status';telar='$_telar_token$'\a\e]133;A;telar='$_telar_token$'\a'
  # The working directory (OSC 7), so telar knows where the next command runs.
  builtin print -rn -- $'\e]7;file://'"${HOST}${PWD//\%/%25}"$'\a'
  # The PATH, when it changed, so completion finds the commands this shell runs.
  if [[ $PATH != ${_telar_path-} ]]; then
    _telar_path=$PATH
    builtin print -rn -- $'\e]6973;telar='$_telar_token';path='${${PATH//\%/%25}//;/%3B}$'\a'
  fi
  # Its aliases and functions, when their count changed: commands no PATH directory holds,
  # which telar's editor must not mark missing. An alias that stands for plain words goes as
  # name=words, %-encoded, so completion follows it to the command it runs.
  if [[ ${#aliases}:${#functions} != $_telar_names ]]; then
    _telar_names=${#aliases}:${#functions}
    builtin local -a names
    builtin local name value
    for name value in ${(kv)aliases}; do
      [[ $name == (_*|*[^[:alnum:]._+:@-]*) ]] && continue
      if [[ -n $value && $value != *[^[:alnum:]._/:@%+,=\ -]* ]]; then
        value=${value//\%/%25}
        names+=("$name=${value// /%20}")
      else
        names+=($name)
      fi
    done
    names+=(${${(k)functions}:#(_*|*[^[:alnum:]._+:@-]*)})
    builtin print -rn -- $'\e]6973;telar='$_telar_token';names='${(j: :)names}$'\a'
  fi
  if [[ -n $_telar_mode ]]; then
    # Only the input mark, so no theme spends time drawing what telar's editor covers.
    PS1=$_telar_input_mark RPROMPT=
    [[ ${SPROMPT-} == "$_telar_start_mark"* ]] || SPROMPT=$_telar_start_mark${SPROMPT-"zsh: correct '%R' to '%r' [nyae]? "}
  else
    [[ $PS1 == *$_telar_input_mark ]] || PS1=${PS1//$_telar_input_mark}$_telar_input_mark
  fi
  # The user's mark, or zsh's own when none is set, after telar's.
  [[ ${PROMPT_EOL_MARK-} == "$_telar_end_mark"* ]] || PROMPT_EOL_MARK=$_telar_end_mark${PROMPT_EOL_MARK-'%B%S%#%s%b'}
  # Bound again at every prompt, in every keymap a line may be edited in, so a configuration that
  # rebinds or resets its keymaps keeps it.
  builtin local keymap
  for keymap in main emacs viins vicmd; do
    builtin bindkey -M $keymap $'\e[6973~' _telar_flush
  done
  if [[ ${precmd_functions[1]} != _telar_save_status || ${precmd_functions[-1]} != _telar_prompt ]]; then
    precmd_functions=(_telar_save_status ${precmd_functions:#_telar_(save_status|prompt)} _telar_prompt)
  fi
}

_telar_preexec() {
  _telar_ran=1
  builtin print -rn -- $'\e]133;C;telar='$_telar_token$'\a'
}

# `ssh` starts remote login shells with the integration too. A function of the user's own
# replaces this one, since .zshrc runs later.
if [[ -n $_telar_ssh && -r $_telar_ssh ]]; then
  ssh() {
    TELAR_SHELL_TOKEN=$_telar_token TELAR_PROMPT_MODE=$_telar_mode TELAR_SHELL_SSH_CONTROL=$_telar_ssh_control /bin/sh $_telar_ssh "$@"
  }
fi

builtin typeset -ga precmd_functions preexec_functions
precmd_functions=(_telar_save_status ${precmd_functions[@]} _telar_prompt)
preexec_functions+=(_telar_preexec)
