#!/usr/bin/env python3
"""Write a zsh history file of harmless commands to evaluate the history UI.

    python3 tools/history_fixture.py /tmp/fixture.zsh_history
    just run history import zsh --file /tmp/fixture.zsh_history

The file holds three days of short commands, enough for a second page, and
three that a row cannot show whole: wide and combining characters, a command
over several lines and one longer than a card. None of them changes anything
when pasted or run, and none comes from anybody's own history.
"""
import argparse
from pathlib import Path
import time

# The newest three, oldest last: what `gui_history.py` walks to and captures.
SPECIAL = [
    "echo 'añadir café ☕ 日本語 👩‍💻 naïve' | wc -c",
    'for word in uno dos tres; do\n  echo "palabra: $word"\ndone',
    '\n'.join(['case "$1" in'] + [f'  option-{index:02d}) echo "choice {index}" ;;' for index in range(1, 31)] +
              ['esac']),
]
ROUTINE = [
    'git status', 'git log --oneline -5', 'ls -la', 'pwd', 'date', 'zig version', 'uname -a', 'whoami',
    'df -h .', 'git diff --stat', 'echo "$SHELL"', 'printenv HOME', 'git branch --show-current', 'wc -l README.md',
    "printf '%s\\n' one two three | sort -r", 'git log --since="2 days ago" --pretty=format:"%h %an %s" | head -n 20',
    'find . -maxdepth 2 -name "*.md" -not -path "./node_modules/*" -not -path "./.git/*" | sort | head -n 40',
]
ROUTINE_COUNT = 140


def histfile(now):
    """The commands as a zsh extended history file, oldest first."""
    entries = [(now - 60 * (index + 2), command) for index, command in enumerate(SPECIAL)]
    # Routine commands every half hour before them, back over three days.
    entries += [(now - 1800 * (index + 1), ROUTINE[index % len(ROUTINE)]) for index in range(ROUTINE_COUNT)]
    lines = [f': {when}:0;' + command.replace('\n', '\\\n') for when, command in sorted(entries)]
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('path', type=Path, help='the history file to write')
    args = parser.parse_args()
    args.path.write_text(histfile(int(time.time())))
    print(args.path)


if __name__ == '__main__':
    main()
