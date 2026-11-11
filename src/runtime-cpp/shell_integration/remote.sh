# telar's shell integration on a host `ssh` reached, run by /bin/sh with the nonce telar
# expects as $1, and `telar` as $2 when telar's editor stands in for the shell's prompt. telar appends the calls: _telar_prepare with the scripts' digest, one
# _telar_put per script, and _telar_start. A step that fails leaves the user's login shell
# starting as usual, without the integration.

_telar_shell=${SHELL:-/bin/sh}
_telar_ready=

# The scripts live where the local runtime keeps them, named after their content.
_telar_prepare() {
  [ -n "${HOME-}" ] || return 1
  _telar_root=${XDG_DATA_HOME:-$HOME/.local/share}/telar/shell-integration/$1
  umask 077
  mkdir -p "$_telar_root" && _telar_ready=1
}

# Writes one script from standard input, unless an earlier session already did: each one is
# written to a temporary name and renamed into place, so a file that exists is complete.
_telar_put() {
  if [ -z "$_telar_ready" ] || [ -f "$_telar_root/$1/$2" ]; then
    cat >/dev/null
    return
  fi
  if mkdir -p "$_telar_root/$1" && cat >"$_telar_root/$1/$2.$$" && mv -f "$_telar_root/$1/$2.$$" "$_telar_root/$1/$2"; then
    return
  fi
  rm -f "$_telar_root/$1/$2.$$"
  _telar_ready=
}

# Answers telar with the nonce and a token of this host's own, then starts the login shell
# with the scripts, as the local runtime does.
_telar_start() {
  _telar_prompt=${2-}
  _telar_token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ -z "$_telar_ready" ] || [ "${#1}" -ne 32 ] || [ "${#_telar_token}" -ne 32 ]; then
    exec "$_telar_shell" -l
  fi
  _telar_name=${_telar_shell##*/}
  case $_telar_name in
    zsh)
      if [ -n "${ZDOTDIR+X}" ]; then
        export TELAR_ZSH_ZDOTDIR="$ZDOTDIR"
      fi
      export ZDOTDIR="$_telar_root/zsh"
      set -- "$1" -l
      ;;
    bash)
      export TELAR_BASH_LOGIN=1
      set -- "$1" --rcfile "$_telar_root/bash/telar.bash" -i
      ;;
    fish)
      if [ -n "${XDG_DATA_DIRS+X}" ]; then
        export TELAR_FISH_XDG_DATA_DIRS="$XDG_DATA_DIRS"
      fi
      export XDG_DATA_DIRS="$_telar_root/fish:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
      set -- "$1" -l
      ;;
    *)
      exec "$_telar_shell" -l
      ;;
  esac
  printf '\033]6973;nest=%s;token=%s;shell=%s\007' "$1" "$_telar_token" "$_telar_name"
  shift
  export TELAR_SHELL_TOKEN="$_telar_token"
  if [ "$_telar_prompt" = telar ]; then
    export TELAR_PROMPT_MODE=telar
  fi
  exec "$_telar_shell" "$@"
}
