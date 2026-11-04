"""Deterministic ASCII alternate-screen trace for native terminal diagnostics."""

FULL_INTERVAL = 8
SCREEN_INTERVAL = 32
ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
WORKLOAD = "ascii-tui-v1"


def row_text(columns, row, sequence):
    prefix = f"{row:03d}:{sequence:06d} "
    return (prefix + "".join(ALPHABET[(column + row * 7 + sequence * 11) % len(ALPHABET)]
                             for column in range(columns)))[:columns]


def changed_rows(rows, sequence):
    if sequence % FULL_INTERVAL == 0:
        return tuple(range(rows))
    count = max(1, rows // 4)
    return tuple((sequence * count + offset) % rows for offset in range(count))


class Trace:
    def __init__(self):
        self.size = None
        self.sequence = None
        self.epochs = []
        self.full_updates = 0
        self.partial_updates = 0
        self.screen_resets = 0
        self.bytes = 0
        self.capture_cell = False

    def draw(self, columns, rows, sequence, capture=False):
        if not 1 <= columns <= 2000 or not 1 <= rows <= 2000 or not 0 <= sequence < 1000000:
            raise ValueError("TUI dimensions or sequence outside fixture bounds")
        resized = self.size != (columns, rows)
        reset = resized or self.sequence is None or (sequence != self.sequence and sequence % SCREEN_INTERVAL == 0)
        full = reset or sequence % FULL_INTERVAL == 0
        selected = tuple(range(rows)) if full else changed_rows(rows, sequence)
        if resized:
            self.epochs = [sequence] * rows
        output = ["\x1b[?25l\x1b[?7l"]
        if reset:
            output.append("\x1b[?1049l\x1b[?1049h\x1b[0m\x1b[2J")
            self.screen_resets += 1
        for row in selected:
            self.epochs[row] = sequence
            if row == 0:
                self.capture_cell = False
            shade = 160 + (sequence + row) % 64
            background = 8 + (sequence + row) % 8
            bold = 1 if (sequence + row) % 3 == 0 else 22
            output.append(f"\x1b[{row + 1};1H\x1b[{bold};38;2;{shade};{shade};{shade};48;2;{background};{background};{background}m")
            output.append(row_text(columns, row, sequence))
        if capture:
            output.append("\x1b[H\x1b[0;38;2;180;180;180mc")
            self.capture_cell = True
        self.size = columns, rows
        self.sequence = sequence
        self.full_updates += int(full)
        self.partial_updates += int(not full)
        data = "".join(output).encode("ascii")
        self.bytes += len(data)
        return data

    def receipt(self):
        if self.size is None:
            return None
        columns, rows = self.size
        text = [list(row_text(columns, row, epoch)) for row, epoch in enumerate(self.epochs)]
        if self.capture_cell:
            text[0][0] = "c"
        text[min(7, rows - 1)][min(19, columns - 1)] = " "
        return dict(workload=WORKLOAD, sequence=self.sequence, columns=columns, rows=rows,
                    row_epochs=self.epochs.copy(), full_updates=self.full_updates,
                    partial_updates=self.partial_updates, screen_resets=self.screen_resets,
                    body_bytes=self.bytes, capture_cell=self.capture_cell,
                    expected_text="\n".join("".join(row) for row in text))
