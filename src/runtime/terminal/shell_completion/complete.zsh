# What zsh would complete at the end of a line, run by `zsh -f -c` with the line as $1, `rc` as
# $2 when the user's own .zshrc is to be read, and as $3 the file compinit keeps its dump in,
# which only the user may write, or nothing for none. The line is data: it reaches the shell that
# completes it as the value of a variable, never as code or as keys typed.
#
# Completion needs zle, and zle needs a terminal: an interactive zsh runs under zpty, and its
# widget sets the line and completes it. compadd only records what it is given, writing each
# match, unquoted and whole, with its description after a tab, to descriptor 3, which is the
# runtime's pipe; a record separator ends the answer. Nothing is listed, so zsh never stops to
# ask whether to show many matches; with -A, compadd reports that it added nothing, whatever it
# matched.
zmodload zsh/zpty 2>/dev/null || exit 0
# The setup the interactive shell evaluates, where comments are not on. A dump makes compinit
# ten times faster, and compinit makes it again when the functions change; a .zshrc may have
# run it already. What is shown for a match names it first, as `word  -- what it does`: only
# what it does is its description.
export TELAR_COMPLETION_LINE=$1 TELAR_COMPLETION_DUMP=$3 TELAR_COMPLETION_SETUP='
if (( ! $+functions[compdef] )); then
  autoload -Uz compinit
  if [[ -n $TELAR_COMPLETION_DUMP ]]; then
    compinit -u -d "$TELAR_COMPLETION_DUMP"
  else
    compinit -u -D
  fi
fi
compadd() {
  setopt localoptions extendedglob
  local -a _telar_hits _telar_shown
  local -A _telar_options
  zparseopts -E -A _telar_options O: A: D: P: p: s: S: d: J: V: X: x: r: R: W: F: M: E: I: i: o:: Q f q U a k l n 1 2 e C
  if (( $+_telar_options[-O] || $+_telar_options[-A] || $+_telar_options[-D] )); then
    builtin compadd "$@"
    return
  fi
  if [[ -n $_telar_options[-d] && $_telar_options[-d] != \(* ]]; then
    _telar_shown=( "${(@P)_telar_options[-d]}" )
  fi
  builtin compadd -A _telar_hits "$@"
  (( $#_telar_hits )) || return 1
  local _telar_hit _telar_word _telar_about
  for _telar_hit in $_telar_hits; do
    _telar_word=$_telar_options[-P]$_telar_options[-p]$_telar_hit$_telar_options[-s]
    if (( $+_telar_options[-Q] )); then
      _telar_word=${(Q)_telar_word}
      _telar_hit=${(Q)_telar_hit}
    fi
    _telar_word=$IPREFIX$_telar_word$ISUFFIX
    [[ -z $_telar_word || $_telar_word == *[[:cntrl:]]* ]] && continue
    if (( $+_telar_options[-f] )) && [[ $_telar_word != */ && -d ${_telar_word/#\~\//$HOME/} ]]; then
      _telar_word+=/
    fi
    _telar_about=${_telar_shown[(r)${(b)_telar_hit}(|[[:blank:]]*)]}
    _telar_about=${${${_telar_about#$_telar_hit}##[[:blank:]]#}##--[[:blank:]]#}
    print -rnu3 -- $_telar_word
    [[ -n $_telar_about ]] && print -rnu3 -- $'"'"'\t'"'"'${_telar_about//[[:cntrl:]]/ }
    print -u3
  done
}
_telar_complete() {
  BUFFER=$TELAR_COMPLETION_LINE
  CURSOR=$#BUFFER
  zle complete-word
  print -nu3 $'"'"'\x1e'"'"'
  exit
}
zle -N _telar_complete
bindkey "\e[6974~" _telar_complete'
exec 3>&1 >/dev/null 2>&1
if [[ $2 == rc ]]; then
  zpty telar ${(q)ZSH_ARGZERO} -i
else
  zpty telar ${(q)ZSH_ARGZERO} -f -i
fi
# Typed ahead of the first prompt, as a terminal's keys can be: whatever prompt a .zshrc sets.
zpty -w telar 'eval "$TELAR_COMPLETION_SETUP"'
# A key no terminal sends and no tty reads as its own: macOS takes ^T for its status line.
zpty -w -n telar $'\e[6974~'
# The pty is drained so the shell never waits to write to it.
while zpty -t telar; do
  zpty -r -t telar _telar_screen || sleep 0.01
done
