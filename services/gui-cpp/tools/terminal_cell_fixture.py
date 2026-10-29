import argparse
import hashlib
import json
from pathlib import Path
import sys
import re
import unicodedata

repository = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(repository / 'tools'))
from terminal_bench_fixture import Fixture, atomic_json, defer_resize, write_all


programming = 'M W fi fl st -> => != == === <= >= <=>'
cases = [
    ('regular', '0', programming),
    ('bold', '1', programming),
    ('italic', '3', programming),
    ('bold_italic', '1;3', programming),
    ('faint', '2', programming),
    ('inverse', '7', programming),
    ('inverse_faint', '2;7', programming),
    ('strike', '9', programming),
    ('underline', '4', programming),
    ('double_underline', '4:2', programming),
    ('curly_underline', '4:3', programming),
    ('dotted_underline', '4:4', programming),
    ('dashed_underline', '4:5', programming),
    ('overline', '53', programming),
    ('color', '38;2;37;149;211;48;2;73;28;105', programming),
    ('faint_color', '2;38;2;37;149;211;48;2;73;28;105', programming),
    ('combining', '0', 'Café á ë o̧ ā Ω Ж λ 中文'),
    ('arabic', '0', 'سلام لا'),
    ('hebrew', '0', 'שלום'),
    ('symbols', '0', '⇧ ⌘ ⌥ ⌃ ⎇ ⌫ ⏎ ⌨ ⛶'),
    ('programming', '0', '--> -> => ==> === !== != <= >= <=> := :: ::: ...'),
    ('colored_backgrounds', '0', '\x1b[41m=\x1b[42m=\x1b[43m=\x1b[0m  \x1b[44m-\x1b[45m>\x1b[0m'),
    ('hidden', '8', 'invisible text'),
    ('faint_strike', '2;9', programming),
    ('tall_combining', '0', 'a' + '\u0301' * 7),
    ('underline_color', '4;58;2;113;42;190', programming),
]

corpus_sha256 = hashlib.sha256(json.dumps(cases, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()


def display_columns(text):
    visible = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    columns = 0
    for character in visible:
        if unicodedata.combining(character):
            continue
        columns += 2 if unicodedata.east_asian_width(character) in ('W', 'F') else 1
    return columns


minimum_columns = len(f'{len(cases):02}') + 1 + max(display_columns(text) for _, _, text in cases)


class CellFixture(Fixture):
    def __init__(self, directory):
        self.drawn_size = None
        super().__init__(directory)

    def draw_background(self):
        with defer_resize():
            self.drawn_size = [self.size.columns, self.size.lines]
            write_all(b'\x1b[?25l\x1b[0m\x1b[2J')
            for index, (_, style, text) in enumerate(cases):
                write_all((f'\x1b[{index+1};1H\x1b[0m{index+1:02} \x1b[{style}m{text}\x1b[0m').encode())

    def record(self):
        with defer_resize():
            if not self.primary and self.phase == 'ready' and self.drawn_size != [self.size.columns, self.size.lines]:
                self.draw_background()
            super().record()
            receipt = json.loads(self.receipt.read_text())
            receipt['cell_fixture'] = dict(corpus_sha256=corpus_sha256, cases=len(cases), minimum_columns=minimum_columns, drawn_size=self.drawn_size)
            atomic_json(self.receipt, receipt)


def main():
    parser = argparse.ArgumentParser(description='Run the shared terminal fixture with a static styled-cell background')
    parser.add_argument('directory', type=Path)
    options = parser.parse_args()
    CellFixture(options.directory.resolve()).run()


if __name__ == '__main__':
    main()
