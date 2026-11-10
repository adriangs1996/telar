# telar shell integration for zsh, loaded once before the user's .zshrc.
# It marks prompts and commands with OSC 133 and signs every mark with the pane's
# token, so telar trusts these marks and ignores the ones a program prints.
(( ${+_telar_token} )) && builtin return 0
builtin typeset -g _telar_token=${TELAR_SHELL_TOKEN-} _telar_ssh=${TELAR_SHELL_SSH-}
builtin unset TELAR_SHELL_TOKEN TELAR_SHELL_SSH
if [[ ${#_telar_token} -ne 32 || $_telar_token == *[^0-9a-f]* ]]; then
  builtin unset _telar_token
  builtin return 0
fi

builtin typeset -gi _telar_status=0
builtin typeset -g _telar_path _telar_names
builtin typeset -g _telar_input_mark=$'%{\e]133;B;telar='$_telar_token$'\a%}'

# First precmd hook, so it reads the command's status before other hooks change it.
_telar_save_status() {
  _telar_status=$?
}

# Last precmd hook, so the input mark survives themes that rebuild PS1 in their hooks.
_telar_prompt() {
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
  [[ $PS1 == *$_telar_input_mark ]] || PS1=${PS1//$_telar_input_mark}$_telar_input_mark
  if [[ ${precmd_functions[1]} != _telar_save_status || ${precmd_functions[-1]} != _telar_prompt ]]; then
    precmd_functions=(_telar_save_status ${precmd_functions:#_telar_(save_status|prompt)} _telar_prompt)
  fi
}

_telar_preexec() {
  builtin print -rn -- $'\e]133;C;telar='$_telar_token$'\a'
}

# `ssh` starts remote login shells with the integration too. A function of the user's own
# replaces this one, since .zshrc runs later.
if [[ -n $_telar_ssh && -r $_telar_ssh ]]; then
  ssh() {
    TELAR_SHELL_TOKEN=$_telar_token /bin/sh $_telar_ssh "$@"
  }
fi

builtin typeset -ga precmd_functions preexec_functions
precmd_functions=(_telar_save_status ${precmd_functions[@]} _telar_prompt)
preexec_functions+=(_telar_preexec)
