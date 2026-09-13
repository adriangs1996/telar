"""Shared terminal fixture for box drawing and italic overhang captures."""


def lines():
    sample = [
        'Box drawing and italic overhang',
        '╭──────────────────────────────╮',
        '│ OpenAI Codex                 │',
        '│ model: test                  │',
        '│ directory: isolated fixture  │',
        '╰──────────────────────────────╯',
        'Tip: New New New, italic ffi ffy Wyj',
        '┏━━━━┳━━━━┓  ╔════╦════╗  ╭────╮',
        '┃    ┃    ┃  ║    ║    ║  │    │',
        '┣━━━━╋━━━━┫  ╠════╬════╣  ╰────╯',
        '┗━━━━┻━━━━┛  ╚════╩════╝  ╱╲╳',
    ]
    sample.extend(f'{0x2500 + row * 16:04X}: ' + ''.join(chr(0x2500 + row * 16 + col) for col in range(16))
                  for row in range(8))
    return sample


def ansi():
    return '\r\n'.join(lines()).replace('New', '\033[3mNew\033[23m').replace(
        'ffi ffy Wyj', '\033[1;3mffi ffy Wyj\033[0m') + '\r\n'
