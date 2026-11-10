# telar shell integration for bash. telar starts bash with --rcfile naming this file,
# the one startup file it can choose that every bash version reads, and drops --login
# because a login shell ignores --rcfile. Read the startup files bash would have read.
if [ -n "${TELAR_BASH_LOGIN-}" ]; then
  builtin unset TELAR_BASH_LOGIN
  if [ -r /etc/profile ]; then builtin source /etc/profile; fi
  for _telar_file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -r "$_telar_file" ]; then
      builtin source "$_telar_file"
      break
    fi
  done
else
  if [ -r /etc/bash.bashrc ]; then builtin source /etc/bash.bashrc; fi
  if [ -r "$HOME/.bashrc" ]; then builtin source "$HOME/.bashrc"; fi
fi
builtin unset _telar_file

# Marks prompts and commands with OSC 133, signed with the pane's token so telar trusts
# them and ignores the ones a program prints. The command mark uses PS0 from bash 4.4, and
# the DEBUG trap before it, unless the user's configuration set its own.
_telar_token=${TELAR_SHELL_TOKEN-}
_telar_ssh=${TELAR_SHELL_SSH-}
builtin unset TELAR_SHELL_TOKEN TELAR_SHELL_SSH
_telar_ps0=
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  _telar_ps0=1
fi
_telar_list_functions=
if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )); then
  _telar_list_functions=1
fi
if [ "${#_telar_token}" -eq 32 ] && [[ $_telar_token != *[!0-9a-f]* ]] && { [ -n "$_telar_ps0" ] || [ -z "$(builtin trap -p DEBUG)" ]; }; then
  _telar_input_mark='\[\e]133;B;telar='"$_telar_token"'\a\]'
  _telar_command_mark='\e]133;C;telar='"$_telar_token"'\a'

  # Runs first and returns the status it read, so the user's prompt commands still see it.
  _telar_begin() {
    _telar_status=$?
    _telar_armed=
    builtin printf '\e]133;D;%s;telar=%s\a\e]133;A;telar=%s\a' "$_telar_status" "$_telar_token" "$_telar_token"
    # The working directory (OSC 7), so telar knows where the next command runs.
    builtin printf '\e]7;file://%s%s\a' "$HOSTNAME" "${PWD//[%]/%25}"
    # The PATH, when it changed, so completion finds the commands this shell runs.
    if [ "$PATH" != "${_telar_path-}" ]; then
      _telar_path=$PATH
      local path=${PATH//[%]/%25}
      builtin printf '\e]6973;telar=%s;path=%s\a' "$_telar_token" "${path//;/%3B}"
    fi
    # Its aliases and functions, when their count changed: commands no PATH directory holds,
    # which telar's editor must not mark missing. From bash 5.3 compgen lists the functions
    # into an array, so every prompt counts them; before, listing them takes a subshell, and
    # only the first prompt and a change of aliases do.
    local functions=
    if [ -n "$_telar_list_functions" ]; then
      local -a _telar_functions
      builtin compgen -V _telar_functions -A function -X '_*'
      functions=${#_telar_functions[@]}
    fi
    if [ "${#BASH_ALIASES[@]}:$functions" != "${_telar_names-}" ]; then
      _telar_names=${#BASH_ALIASES[@]}:$functions
      # An alias that stands for plain words goes as name=words, %-encoded, so completion
      # follows it to the command it runs.
      local IFS=' ' names= name value
      for name in "${!BASH_ALIASES[@]}"; do
        value=${BASH_ALIASES[$name]}
        case $name in _*|*[!A-Za-z0-9._+:@-]*) continue ;; esac
        case $value in
          ''|*[!A-Za-z0-9._/:@%+,=\ -]*) names+=" $name" ;;
          *) value=${value//%/%25}; names+=" $name=${value// /%20}" ;;
        esac
      done
      if [ -n "$_telar_list_functions" ]; then
        names+=" ${_telar_functions[*]}"
      else
        names+=" $(builtin compgen -A function -X '_*')"
      fi
      builtin printf '\e]6973;telar=%s;names=%s\a' "$_telar_token" "${names//$'\n'/ }"
    fi
    builtin return "$_telar_status"
  }

  # Runs last, so the marks survive prompt commands that rebuild PS1 or PS0.
  _telar_end() {
    case $PS1 in
      *"$_telar_input_mark") ;;
      *) PS1=${PS1//"$_telar_input_mark"/}$_telar_input_mark ;;
    esac
    if [ -n "$_telar_ps0" ]; then
      case ${PS0-} in
        *"$_telar_command_mark") ;;
        *) PS0=${PS0//"$_telar_command_mark"/}$_telar_command_mark ;;
      esac
    else
      _telar_armed=1
    fi
  }

  if [ -z "$_telar_ps0" ]; then
    # Before 4.4: the first command after a prompt marks the start of its output. The prompt
    # commands themselves run under the trap too, and must not.
    _telar_preexec() {
      if [ -n "${_telar_armed-}" ] && [ "$BASH_COMMAND" != _telar_begin ]; then
        _telar_armed=
        builtin printf '\e]133;C;telar=%s\a' "$_telar_token"
      fi
    }
    builtin trap '_telar_preexec' DEBUG
  fi

  # `ssh` starts remote login shells with the integration too, unless the user's
  # configuration defined its own.
  if [ -n "$_telar_ssh" ] && [ -r "$_telar_ssh" ] && ! builtin declare -F ssh >/dev/null; then
    ssh() {
      TELAR_SHELL_TOKEN=$_telar_token /bin/sh "$_telar_ssh" "$@"
    }
  fi

  if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
    PROMPT_COMMAND=(_telar_begin "${PROMPT_COMMAND[@]}" _telar_end)
  else
    PROMPT_COMMAND=$'_telar_begin\n'"${PROMPT_COMMAND-}"$'\n_telar_end'
  fi
else
  builtin unset _telar_token
fi
