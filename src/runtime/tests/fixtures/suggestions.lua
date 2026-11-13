return {
  api_version = 2,
  runtime = {
    session = { persist = false },
    engine = {
      timeout_ms = 1000,
      command = { '/bin/sh', '-c', [[
        while IFS= read -r request; do
          case "$request" in
            *get_last_assistant_text*)
              printf '%s\n' '{"type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"git status"}}'
              ;;
            *)
              printf '%s\n' '{"type":"response","command":"prompt","success":true}' '{"type":"agent_settled"}'
              ;;
          esac
        done
      ]] },
    },
  },
}
