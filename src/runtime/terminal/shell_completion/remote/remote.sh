# What a host `ssh` reached completes, run there by /bin/sh through the connection the pane's
# session shares, as `telar <question> [rc]`. The question is one of the runtime's own words:
# zsh, bash or fish for what that shell would complete at the end of the line, with `rc` when
# it reads the user's own configuration, or paths, directories or executables for the entries
# of the one directory the line's word names, or one of the providers' words below, for what
# the runtime reads as its own providers do. The runtime appends the script of the shell, in
# _telar_script, and the call to _telar_complete.
#
# Standard input holds the data, never code: the directory the remote shell works in, empty for
# the home ssh starts in, then the line, each on a line of its own. They reach the shells as
# arguments and the listing as quoted words, never as code to run or keys to type. Whatever
# the login shell's own startup printed goes before the group separator that starts the answer.

# zsh runs the dump that makes compinit fast as code: its directory must be the user's alone.
_telar_dump() {
  _telar_cache=${XDG_DATA_HOME:-$HOME/.local/share}/telar/shell-completion
  case $_telar_cache in
    /*) ;;
    *) return ;;
  esac
  (umask 077 && mkdir -p "$_telar_cache") 2>/dev/null
  if [ -n "$(find "$_telar_cache" -prune -type d -user "$(id -u)" ! -perm -g+w ! -perm -o+w 2>/dev/null)" ]; then
    printf %s "$_telar_cache/zcompdump"
  fi
}

# The shell runs as it does on the runtime's host: apart from the user's configuration unless
# asked for it, with the PATH, the home and the locale, and nothing a terminal would set. The
# login shell is the one when it is of that kind, since a non-interactive PATH may not hold it.
_telar_shell() {
  if [ "${SHELL##*/}" = "$1" ] && [ -x "$SHELL" ]; then
    _telar_program=$SHELL
  else
    _telar_program=$(command -v "$1" 2>/dev/null) || return
  fi
  case $_telar_program in
    /*) ;;
    *) return ;;
  esac
  set -- "$1" "${2-}" env -i PATH="$PATH" HOME="$HOME" TERM=dumb ${LANG+"LANG=$LANG"} ${LC_ALL+"LC_ALL=$LC_ALL"} ${LC_CTYPE+"LC_CTYPE=$LC_CTYPE"} "$_telar_program"
  _telar_question=$1
  _telar_configuration=$2
  shift 2
  printf '\035'
  case $_telar_question in
    zsh) exec "$@" -f -c "$_telar_script" zsh "$_telar_line" "$_telar_configuration" "$(_telar_dump)" ;;
    bash) exec "$@" --norc --noprofile -c "$_telar_script" bash "$_telar_line" "$_telar_configuration" ;;
    fish)
      if [ "$_telar_configuration" = rc ]; then
        exec "$@" -c "$_telar_script" -- "$_telar_line" rc
      fi
      exec "$@" --no-config -c "$_telar_script" -- "$_telar_line" ""
      ;;
  esac
}

# The entries of the one directory the word names, written back as typed: the word up to its
# last slash, then the name, with a slash after a directory. `~/` is the home; a word with `$`
# or `~user` names no directory telar would look up. Hidden entries only for a name that starts
# with a dot, and names a line cannot hold are left out.
_telar_entries() {
  _telar_shown=
  case $_telar_line in
    */*) _telar_shown=${_telar_line%/*}/ ;;
  esac
  _telar_partial=${_telar_line##*/}
  case $_telar_shown in
    *'$'*) return ;;
    '~/'*) _telar_base=$HOME/${_telar_shown#'~/'} ;;
    '~'*) return ;;
    *) _telar_base=$_telar_shown ;;
  esac
  printf '\035'
  _telar_count=0
  for _telar_entry in "$_telar_base$_telar_partial"*; do
    [ -e "$_telar_entry" ] || [ -L "$_telar_entry" ] || continue
    _telar_count=$((_telar_count + 1))
    [ "$_telar_count" -le 4096 ] || break
    _telar_name=${_telar_entry#"$_telar_base"}
    case $_telar_name in
      *[[:cntrl:]]*) continue ;;
    esac
    if [ -d "$_telar_entry" ]; then
      printf '%s/\n' "$_telar_shown$_telar_name"
    elif [ "$1" = paths ] || { [ "$1" = executables ] && [ -f "$_telar_entry" ] && [ -x "$_telar_entry" ]; }; then
      printf '%s\n' "$_telar_shown$_telar_name"
    fi
  done
}

# The programs on the host's PATH whose names start with the word, a line each. A word with a
# slash names a path, which the entries answer.
_telar_commands() {
  case $_telar_line in
    */*) return ;;
  esac
  printf '\035'
  _telar_count=0
  _telar_rest=$PATH:
  while [ -n "$_telar_rest" ]; do
    _telar_folder=${_telar_rest%%:*}
    _telar_rest=${_telar_rest#*:}
    case $_telar_folder in
      /*) ;;
      *) continue ;;
    esac
    for _telar_entry in "$_telar_folder/$_telar_line"*; do
      _telar_count=$((_telar_count + 1))
      [ "$_telar_count" -le 65536 ] || return
      [ -f "$_telar_entry" ] && [ -x "$_telar_entry" ] || continue
      _telar_name=${_telar_entry##*/}
      case $_telar_name in
        .* | *[[:cntrl:]]*) continue ;;
      esac
      printf '%s\n' "$_telar_name"
    done
  done
}

# What git lists of the repository the directory is in: references a line each, its remotes, or
# the count of its stashes. None of these commands runs a hook or a program a repository's
# configuration names.
_telar_git() {
  case $1 in
    branches) set -- for-each-ref --format=%\(refname\) refs/heads refs/remotes ;;
    references) set -- for-each-ref --format=%\(refname\) refs/heads refs/remotes refs/tags ;;
    remotes) set -- remote ;;
    stashes) set -- rev-list --walk-reflogs --count refs/stash ;;
  esac
  printf '\035'
  env -i PATH="$PATH" HOME="$HOME" GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false "$@" 2>/dev/null
}

# The user's processes, a line each: the id, then the name.
_telar_processes() {
  printf '\035'
  ps -o pid= -o comm= -u "$(id -u)" 2>/dev/null
}

# The first of the files named that the directory holds, or with `nearest` the closest of its
# parents, as make, just, npm and compose find theirs. No more than an answer holds is sent, and
# the runtime reads no more; a file that is not a regular one is passed over, as is an empty one.
_telar_file() {
  _telar_up=$1
  shift
  printf '\035'
  _telar_here=$PWD
  _telar_depth=0
  while [ "$_telar_depth" -lt 32 ]; do
    for _telar_name in "$@"; do
      _telar_found=${_telar_here%/}/$_telar_name
      if [ -f "$_telar_found" ] && [ -s "$_telar_found" ]; then
        dd if="$_telar_found" bs=65537 count=1 2>/dev/null
        return
      fi
    done
    if [ "$_telar_up" != nearest ] || [ "$_telar_here" = / ]; then
      return
    fi
    _telar_here=${_telar_here%/*}
    _telar_here=${_telar_here:-/}
    _telar_depth=$((_telar_depth + 1))
  done
}

_telar_complete() {
  IFS= read -r _telar_directory && IFS= read -r _telar_line || return
  if [ -n "$_telar_directory" ]; then
    cd "$_telar_directory" 2>/dev/null || return
  fi
  case $1 in
    zsh | bash | fish) _telar_shell "$1" "${2-}" ;;
    paths | directories | executables) _telar_entries "$1" ;;
    commands) _telar_commands ;;
    branches | references | remotes | stashes) _telar_git "$1" ;;
    processes) _telar_processes ;;
    makefile) _telar_file here GNUmakefile makefile Makefile ;;
    justfile) _telar_file nearest justfile Justfile .justfile ;;
    package) _telar_file nearest package.json ;;
    compose) _telar_file nearest compose.yaml compose.yml docker-compose.yaml docker-compose.yml ;;
  esac
}
