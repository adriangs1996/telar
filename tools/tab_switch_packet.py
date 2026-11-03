"""Opaque terminal-cell marker for a tab identity and a fresh content generation."""

TAB_LIMIT = 16
GENERATION_LIMIT = 65535
DATA_CELLS = 7
MARKER_ROW = 8
MARKER_COLUMN = 20
ANCHOR_RGB = (230, 20, 60)


def checksum(tab, generation):
    value = 0
    for byte in (tab, generation >> 8, generation & 255):
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ (7 if value & 128 else 0)) & 255
    return value


def nibbles(tab, generation):
    if not 0 <= tab < TAB_LIMIT or not 1 <= generation <= GENERATION_LIMIT:
        raise ValueError('invalid tab identity or content generation')
    check = checksum(tab, generation)
    return [tab, (generation >> 12) & 15, (generation >> 8) & 15,
            (generation >> 4) & 15, generation & 15, check >> 4, check & 15]


def marker(tab, generation):
    cells = [ANCHOR_RGB] + [(8 + 16 * value,) * 3 for value in nibbles(tab, generation)]
    return (f'\x1b[?25l\x1b[{MARKER_ROW};{MARKER_COLUMN}H'.encode() +
            b''.join(f'\x1b[48;2;{red};{green};{blue}m '.encode() for red, green, blue in cells) +
            b'\x1b[0m\x1b[H')
