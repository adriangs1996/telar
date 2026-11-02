import re
import sys
from pathlib import Path


def main():
    source = Path(sys.argv[1]).read_text()
    switch = re.search(r"return\s+switch\s*\(codepoint\)\s*\{(.*?)\};", source, re.DOTALL)
    if not switch:
        raise ValueError("Missing box edge switch")

    case_pattern = r"(0x[0-9a-f]+)\s*=>\s*\.\{(.*?)\},"
    cases = re.findall(case_pattern, switch[1], re.DOTALL)
    remainder = re.sub(case_pattern, "", switch[1], flags=re.DOTALL)
    if not re.fullmatch(r"\s*else\s*=>\s*null\s*,\s*", remainder):
        raise ValueError("Unsupported box edge switch case")

    first_codepoint, last_codepoint = 0x2500, 0x257F
    directions = ("up", "right", "down", "left")
    weights = {"none": "none", "light": "light", "heavy": "heavy", "double": "double_line"}
    table = {}
    for codepoint, body in cases:
        codepoint = int(codepoint, 16)
        fields = re.findall(r"\.([a-z]+)\s*=\s*\.([a-z]+)\s*,?", body)
        if not first_codepoint <= codepoint <= last_codepoint or codepoint in table:
            raise ValueError("Invalid or duplicated box codepoint")
        if not fields or re.sub(r"\.([a-z]+)\s*=\s*\.([a-z]+)\s*,?", "", body).strip():
            raise ValueError("Unsupported box edge fields")
        if len(dict(fields)) != len(fields) or any(direction not in directions or weight not in weights for direction, weight in fields):
            raise ValueError("Invalid or duplicated box edge")
        table[codepoint] = dict(fields)

    lines = ["#pragma once", "", '#include "terminal/glyphs/box_edges.hpp"', "#include <array>", "", "namespace telar::gui::glyphs {", "", "inline constexpr auto box_edge_table = std::to_array<BoxEdges>({"]
    for codepoint in range(first_codepoint, last_codepoint + 1):
        fields = table.get(codepoint, {})
        values = ", ".join(f".{direction} = BoxWeight::{weights[fields[direction]]}" for direction in directions if direction in fields)
        lines.append(f"    {{{values}}},")
    lines.extend(["});", "", "}", ""])
    target = Path(sys.argv[2])
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
