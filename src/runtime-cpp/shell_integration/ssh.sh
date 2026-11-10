# telar's ssh, run by the integrated shell's `ssh` function with the pane's token in
# TELAR_SHELL_TOKEN. An interactive session starts the remote login shell with telar's
# integration; anything else (a remote command, forwarding only, -O, -Q, -G, -V, a
# RemoteCommand or RequestTTY no in ssh_config) runs ssh unchanged.
_telar_token=${TELAR_SHELL_TOKEN-}
unset TELAR_SHELL_TOKEN

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

_telar_remote=${0%/*}/remote
if [ "${#_telar_token}" -eq 32 ] && [ -t 0 ] && [ -t 1 ] && [ -r "$_telar_remote" ] && _telar_session "$@" && _telar_configured "$@"; then
  _telar_nonce=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ "${#_telar_nonce}" -eq 32 ]; then
    # Signed, so telar expects the remote shell to answer with this nonce, once.
    printf '\033]6973;telar=%s;nest=%s\007' "$_telar_token" "$_telar_nonce"
    unset _telar_token
    exec ssh -t "$@" "$(cat "$_telar_remote") $_telar_nonce"
  fi
fi
unset _telar_token
exec ssh "$@"
