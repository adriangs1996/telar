#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import sys


def main():
    manifest = json.loads(subprocess.check_output([sys.argv[1]], text=True))
    cell = manifest["types"]["GhosttyCell"]
    if cell["kind"] != "packed" or cell["size"] != 8:
        raise ValueError("Unsupported libghostty-vt cell representation")

    fields = dict(cell["bits"])
    content = fields.pop("content")
    for arm in content["arms"].values():
        for name, field in arm["bits"].items():
            fields[name] = dict(field, lsb=field["lsb"] + content["lsb"])

    lines = ["#pragma once", "", "#include <cstdint>", "", "namespace telar::runtime::cell_layout {", ""]
    for name, field in fields.items():
        name = "protected_cell" if name == "protected" else name
        mask = (1 << field["width"]) - 1
        lines += [f"inline constexpr std::uint64_t {name}(std::uint64_t cell) noexcept {{",
                  f"  return (cell >> {field['lsb']}) & {mask}ULL;", "}", ""]

    lines += ["}", ""]
    Path(sys.argv[2]).write_text("\n".join(lines))


if __name__ == "__main__":
    main()
