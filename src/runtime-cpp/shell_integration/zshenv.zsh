# telar shell integration for zsh, read as .zshenv because telar pointed ZDOTDIR here.
# Restore the user's ZDOTDIR first, so every later startup file is the user's own.
if [[ -n ${TELAR_ZSH_ZDOTDIR+X} ]]; then
  builtin export ZDOTDIR=$TELAR_ZSH_ZDOTDIR
  builtin unset TELAR_ZSH_ZDOTDIR
else
  builtin unset ZDOTDIR
fi

{
  builtin typeset _telar_file=${ZDOTDIR-$HOME}/.zshenv
  [[ ! -r $_telar_file ]] || builtin source -- $_telar_file
} always {
  if [[ -o interactive ]]; then
    _telar_file=${${(%):-%x}:A:h}/telar.zsh
    [[ ! -r $_telar_file ]] || builtin source -- $_telar_file
  fi
  builtin unset _telar_file
}
