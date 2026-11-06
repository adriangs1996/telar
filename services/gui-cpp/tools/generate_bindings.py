import json
import re
import sys
from pathlib import Path


def action_name(source: str) -> tuple[str, int]:
    source = source.strip().rstrip(",").strip()
    plain = re.fullmatch(r"\.([a-z_]+)", source)
    if plain:
        return {"enter_copy_mode": "copy_mode"}.get(plain[1], plain[1]), 0

    payload = re.fullmatch(r"\.\{\s*\.([a-z_]+)\s*=\s*(\.[a-z_]+|-?\d+)\s*\}", source)
    if not payload:
        raise ValueError(f"Unsupported default action: {source}")

    kind, argument = payload.groups()
    if kind == "select_tab":
        return kind, int(argument)
    if kind == "select_tab_offset":
        return "next_tab" if int(argument) == 1 else "previous_tab", 0
    if kind == "select_machine_offset":
        return "next_machine" if int(argument) == 1 else "previous_machine", 0

    stems = {"scroll_pane": "scroll_pane", "split_pane": "split", "focus_pane": "focus", "resize_pane": "resize", "resize_sidebar": "resize_sidebar", "move_tab": "move_tab"}
    return f"{stems[kind]}_{argument.removeprefix('.')}", 0


def chord(source: str) -> str:
    parts = source.split("+")
    key = parts[-1]
    modifiers = " | ".join(f"static_cast<unsigned>(KeyChord::Modifier::{part})" for part in parts[:-1])
    if key in {"left", "right", "up", "down"}:
        fields = f".key = KeyChord::Key::{key}"
    elif len(key) == 1 and key.isascii():
        character = "'" + key.replace("\\", "\\\\").replace("'", "\\'") + "'"
        fields = f".key = KeyChord::Key::character, .character = {character}"
    else:
        raise ValueError(f"Unsupported default chord: {source}")

    if modifiers:
        fields += f", .modifiers = {modifiers}"
    return f"KeyChord{{{fields}}}"


def main() -> None:
    source = Path(sys.argv[1]).read_text()
    pattern = r'try prefixed\(\s*prefix,\s*("(?:[^"\\]|\\.)*"),\s*(.*?)\s*\)'
    bindings = re.findall(pattern, source, re.DOTALL)
    expected = int(re.search(r"pub const count = (\d+);", source)[1])
    if len(bindings) != expected:
        raise ValueError(f"Expected {expected} default bindings, found {len(bindings)}")

    lines = ["", "", "namespace telar::gui {", "", "struct DefaultBinding {", "  KeyChord suffix;", "  BindingAction action;", "};", "", "inline constexpr auto default_bindings = std::to_array<DefaultBinding>({"]
    for key, action in bindings:
        kind, parameter = action_name(action)
        fields = f".kind = BindingActionKind::{kind}"
        if parameter:
            fields += f", .parameter = {parameter}"
        lines.append(f"  {{.suffix = {chord(json.loads(key))}, .action = BindingAction{{{fields}}}}},")
    lines.extend(["});", "", "}", ""])
    target = Path(sys.argv[2])
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
