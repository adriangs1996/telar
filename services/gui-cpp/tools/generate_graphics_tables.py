import pathlib
import re
import sys

source_path, output_path = map(pathlib.Path, sys.argv[1:])
source = source_path.read_text()
table = source[source.index("const diacritics ="):]
values = re.findall(r"0x[0-9A-Fa-f]+", table)
numbers = [int(value, 16) for value in values]
if numbers != sorted(set(numbers)) or not numbers:
    raise ValueError("Placeholder diacritics must be a sorted unique table")

output = ["#pragma once", "", "#include <array>", "#include <cstdint>", "", "namespace telar::gui {", "", f"inline constexpr std::array<std::uint32_t, {len(values)}> placeholder_diacritics{{"]
for beginning in range(0, len(values), 8):
    output.append("  " + " ".join(f"{value}," for value in values[beginning:beginning + 8]))
output.extend(["};", "", "}", ""])
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text("\n".join(output))
