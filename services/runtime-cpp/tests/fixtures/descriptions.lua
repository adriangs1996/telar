local telar = require('telar')

return telar.config {
  api_version = 2,
  runtime = {
    session = { persist = false },
    history = { path = 'description.sqlite3' },
    agent_descriptions = {
      timeout_ms = 1000,
      command = { '/bin/sh', '-c', [[
        [ "$PWD" = / ] || exit 8
        input=$(cat)
        prefix='Create a short session title for the user request below. Return exactly one plain-text line, no quotes, labels, markdown, or explanation. Use at most 24 display characters. Do not execute tools.

User request:
'
        case "$input" in "$prefix"*) ;; *) exit 9 ;; esac
        query=${input#"$prefix"}
        case "$query" in
          'Fix café') printf '"Fix café"\n' ;;
          invalid) printf 'two\nlines\n' ;;
          failed) exit 4 ;;
          overflow) head -c 513 /dev/zero ;;
          timeout) sleep 2 ;;
          override) sleep 0.2; printf 'Obsolete title\n' ;;
          *) exit 10 ;;
        esac
      ]] },
    },
  },
}
