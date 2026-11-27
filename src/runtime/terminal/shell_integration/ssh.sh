# telar's ssh, run by the integrated shell's `ssh` function with the pane's token in
# TELAR_SHELL_TOKEN, TELAR_PROMPT_MODE=telar when telar's editor stands in for the prompt,
# which the remote shell then follows too, and in TELAR_SHELL_SSH_CONTROL the runtime's private
# directory for the sockets of shared connections. An interactive session starts the remote login shell with telar's
# integration; anything else (a remote command, forwarding only, -O, -Q, -G, -V, a
# RemoteCommand or RequestTTY no in ssh_config) runs ssh unchanged.
_telar_token=${TELAR_SHELL_TOKEN-}
_telar_mode=
if [ "${TELAR_PROMPT_MODE-}" = telar ]; then
  _telar_mode=' telar'
fi
_telar_directory=${TELAR_SHELL_SSH_CONTROL-}
unset TELAR_SHELL_TOKEN TELAR_PROMPT_MODE TELAR_SHELL_SSH_CONTROL

# Whether the arguments open a session without a command. ssh reads options after the
# destination too, so parsing goes on past it.
_telar_session() {
  _telar_host=
  while [ "$#" -gt 0 ]; do
    case $1 in
      --)
        shift
        if [ -z "$_telar_host" ] && [ "$#" -gt 0 ]; then
          shift
          _telar_host=1
        fi
        [ "$#" -eq 0 ] && [ -n "$_telar_host" ]
        return
        ;;
      -?*)
        _telar_flags=${1#-}
        shift
        while [ -n "$_telar_flags" ]; do
          _telar_flag=${_telar_flags%"${_telar_flags#?}"}
          _telar_flags=${_telar_flags#?}
          case $_telar_flag in
            [GOQVW]) return 1 ;;
            [BbcDEeFIiJLlmoPpRSw])
              if [ -z "$_telar_flags" ]; then
                [ "$#" -gt 0 ] || return 1
                shift
              fi
              _telar_flags=
              ;;
          esac
        done
        ;;
      *)
        [ -z "$_telar_host" ] || return 1
        _telar_host=1
        shift
        ;;
    esac
  done
  [ -n "$_telar_host" ]
}

# What ssh_config adds for this destination, read without connecting.
_telar_configured() {
  _telar_config=$(command ssh -G "$@" 2>/dev/null) || return 1
  case $_telar_config in
    *"
remotecommand "* | *"
requesttty no"* | *"
requesttty false"* | *"
sessiontype "[!d]* | *"
stdinnull yes"*) return 1 ;;
  esac
}

# The value of `$1` in what ssh_config adds, or nothing.
_telar_setting() {
  case $_telar_config in
    *"
$1 "*)
      _telar_value=${_telar_config#*"
$1 "}
      _telar_value=${_telar_value%%"
"*}
      ;;
    *) _telar_value= ;;
  esac
}

# The socket of the connection the session shares, through which telar asks the host to
# complete a line without typing into the pane. A ControlPath of the user's own is theirs to
# keep: telar reads the socket it names, once it is one. Without one, the session shares its
# connection through a socket in the runtime's private directory, which lives as long as it does,
# named %C so that sessions to one host share one; where that name is too long for ssh to bind
# with the suffix it adds while binding, as beneath macOS's TMPDIR, the session's own random
# name. A path telar would refuse shares nothing.
_telar_share() {
  _telar_control=
  _telar_shared=
  _telar_setting controlpath
  if [ -n "$_telar_value" ]; then
    _telar_control=$_telar_value
    _telar_setting controlmaster
    if [ "$_telar_value" = false ] && [ ! -S "$_telar_control" ]; then
      _telar_control=
    fi
  elif [ -n "$_telar_directory" ] && [ -d "$_telar_directory" ] && [ -O "$_telar_directory" ]; then
    _telar_name=%C
    _telar_config=$(command ssh -G -o ControlPath="$_telar_directory/%C" "$@" 2>/dev/null) || return 0
    _telar_setting controlpath
    _telar_control=$_telar_value
    if [ "${#_telar_control}" -gt 86 ]; then
      _telar_name=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
      _telar_control=$_telar_directory/$_telar_name
      [ "${#_telar_name}" -eq 16 ] || _telar_control=
    fi
    _telar_shared=1
  fi
  case $_telar_control in
    /*[!A-Za-z0-9/._@+,:=-]* | */./* | */../* | */. | */.. | *//*) _telar_control= ;;
    /*) [ "${#_telar_control}" -le 86 ] || _telar_control= ;;
    *) _telar_control= ;;
  esac
  [ -n "$_telar_control" ] || _telar_shared=
}

_telar_remote=${0%/*}/remote
if [ "${#_telar_token}" -eq 32 ] && [ -t 0 ] && [ -t 1 ] && [ -r "$_telar_remote" ] && _telar_session "$@" && _telar_configured "$@"; then
  _telar_nonce=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ "${#_telar_nonce}" -eq 32 ]; then
    _telar_share "$@"
    # Signed, so telar expects the remote shell to answer with this nonce, once.
    printf '\033]6973;telar=%s;nest=%s%s\007' "$_telar_token" "$_telar_nonce" "${_telar_control:+;control=$_telar_control}"
    unset _telar_token
    if [ -n "$_telar_shared" ]; then
      exec ssh -o ControlMaster=auto -o ControlPath="$_telar_directory/$_telar_name" -o ControlPersist=no -t "$@" "$(cat "$_telar_remote") $_telar_nonce$_telar_mode"
    fi
    exec ssh -t "$@" "$(cat "$_telar_remote") $_telar_nonce$_telar_mode"
  fi
fi
unset _telar_token
exec ssh "$@"
