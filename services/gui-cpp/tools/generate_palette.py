import json
import re
import sys
from pathlib import Path

from generate_bindings import action_name


def main() -> None:
    source = Path(sys.argv[1]).read_text()
    catalogue = re.search(r"pub const entries = \[_\]CommandEntry\{(.*?)\n\};", source, re.DOTALL)
    if catalogue is None:
        raise ValueError("Missing original command palette catalogue")

    pattern = r'\.\{\s*\.action\s*=\s*(.*?)\s*,\s*\.label\s*=\s*("(?:[^"\\]|\\.)*")\s*,?\s*\}'
    entries = list(re.finditer(pattern, catalogue[1], re.DOTALL))
    if not entries or re.sub(pattern, "", catalogue[1], flags=re.DOTALL).strip(" \n\t,"):
        raise ValueError("Unrecognized original command palette entry")

    lines = ["#pragma once", "", '#include "input/action.hpp"', "#include <array>", "#include <string_view>", "", "namespace telar::gui {", "", "struct PaletteAction {", "  BindingActionKind action;", "  std::string_view label;", "};", "", "inline constexpr auto palette_actions = std::to_array<PaletteAction>({"]
    for entry in entries:
        kind, parameter = action_name(entry[1])
        if parameter:
            raise ValueError("Parameterized palette action requires an explicit target")

        label = json.dumps(json.loads(entry[2]), ensure_ascii=False)
        lines.append(f"  {{.action = BindingActionKind::{kind}, .label = {label}}},")

    lines.extend(["});", "", "}", ""])
    target = Path(sys.argv[2])
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
