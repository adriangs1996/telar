# What bash would complete at the end of a line, run by `bash --norc --noprofile -c` with the
# line as $1 and `rc` as $2 when the user's own .bashrc is to be read. The line is data: it is
# split into COMP_WORDS here, character by character, and never evaluated.
#
# Readline is not there to call the command's completion function, so this does what it would:
# bash-completion is loaded, the function `complete -F` names is called with COMP_WORDS,
# COMP_CWORD, COMP_LINE and COMP_POINT, and COMPREPLY is written one match a line, whole: the
# part of the word before an `=` or a `:`, which readline would not have replaced, goes first.
_telar_line=$1
if [[ $2 == rc && -r ~/.bashrc ]]; then
  . ~/.bashrc >/dev/null 2>&1
fi
if ! declare -F __load_completion >/dev/null; then
  for _telar_file in "${BASH%/bin/*}/share/bash-completion/bash_completion" /usr/local/share/bash-completion/bash_completion /opt/homebrew/share/bash-completion/bash_completion /usr/share/bash-completion/bash_completion /opt/homebrew/etc/bash_completion /usr/local/etc/bash_completion /etc/bash_completion; do
    if [[ -r $_telar_file ]]; then
      . "$_telar_file" >/dev/null 2>&1
      break
    fi
  done
fi

# Only readline may call compopt; a function records whether the matches are file names.
_telar_filenames=
compopt() {
  local _telar_option
  for _telar_option; do
    [[ $_telar_option == filenames ]] && _telar_filenames=1
  done
  return 0
}

# Words as readline gives them: split at blanks outside quotes and kept as typed, the last one
# also without its quotes. A `;`, `|` or `&` starts another command.
COMP_WORDS=()
_telar_word= _telar_plain= _telar_kept= _telar_quote= _telar_escaped= _telar_started=
for ((_telar_index = 0; _telar_index < ${#_telar_line}; _telar_index++)); do
  _telar_character=${_telar_line:_telar_index:1}
  if [[ -n $_telar_escaped ]]; then
    _telar_word+=$_telar_character _telar_plain+=$_telar_character _telar_escaped=
    continue
  fi
  if [[ $_telar_character == \\ && $_telar_quote != "'" ]]; then
    _telar_word+=$_telar_character _telar_escaped=1 _telar_started=1
    continue
  fi
  if [[ -n $_telar_quote ]]; then
    _telar_word+=$_telar_character
    if [[ $_telar_character == "$_telar_quote" ]]; then
      _telar_quote=
    else
      _telar_plain+=$_telar_character
    fi
    continue
  fi
  case $_telar_character in
    [\'\"]) _telar_quote=$_telar_character _telar_word+=$_telar_character _telar_started=1 ;;
    [[:blank:]])
      [[ -n $_telar_started ]] && COMP_WORDS+=("$_telar_word")
      _telar_word= _telar_plain= _telar_kept= _telar_started=
      ;;
    [\;\|\&]) COMP_WORDS=() _telar_word= _telar_plain= _telar_kept= _telar_started= ;;
    [=:]) _telar_word+=$_telar_character _telar_plain+=$_telar_character _telar_kept=$_telar_plain _telar_started=1 ;;
    *) _telar_word+=$_telar_character _telar_plain+=$_telar_character _telar_started=1 ;;
  esac
done
COMP_WORDS+=("$_telar_word")
COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
((COMP_CWORD > 0)) || exit 0
COMP_LINE=$_telar_line COMP_POINT=${#_telar_line} COMP_TYPE=9 COMP_KEY=9
# As readline breaks words, so the functions trim what it would not replace.
COMP_WORDBREAKS=$' \t\n"\'><=;|&(:'

_telar_command=${COMP_WORDS[0]}
_telar_spec=$(complete -p -- "$_telar_command" 2>/dev/null)
if [[ -z $_telar_spec ]] && declare -F __load_completion >/dev/null; then
  __load_completion "$_telar_command" >/dev/null 2>&1
  _telar_spec=$(complete -p -- "$_telar_command" 2>/dev/null)
fi
[[ $_telar_spec =~ \ -F\ ([^ ]+) ]] || exit 0
_telar_function=${BASH_REMATCH[1]}
[[ " $_telar_spec " == *" -o filenames "* ]] && _telar_filenames=1

COMPREPLY=()
"$_telar_function" "$_telar_command" "${COMP_WORDS[COMP_CWORD]}" "${COMP_WORDS[COMP_CWORD - 1]}" >/dev/null 2>&1 </dev/null
for _telar_reply in "${COMPREPLY[@]}"; do
  # A match that ends in a blank asks readline not to add one.
  _telar_reply=${_telar_reply%" "}
  _telar_match=$_telar_kept$_telar_reply
  [[ -z $_telar_reply || $_telar_match == *[[:cntrl:]]* ]] && continue
  _telar_path=$_telar_match
  [[ $_telar_path == "~/"* ]] && _telar_path=$HOME/${_telar_path#"~/"}
  if [[ -n $_telar_filenames && $_telar_match != */ && -d $_telar_path ]]; then
    _telar_match+=/
  fi
  printf '%s\n' "$_telar_match"
done
