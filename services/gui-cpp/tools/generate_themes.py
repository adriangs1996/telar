import pathlib
import re
import sys


def balanced(source, beginning):
    depth = 0
    for position in range(beginning, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return source[beginning + 1 : position], position + 1
    raise ValueError("Unbalanced theme definition")


def blocks(source):
    result = {}
    position = 0
    pattern = re.compile(r"((?:\.\w+\s*,?\s*)+)\s*=>\s*\.\{")
    while match := pattern.search(source, position):
        body, position = balanced(source, match.end() - 1)
        for name in re.findall(r"\.(\w+)", match[1]):
            result[name] = body
    return result


def assignments(source):
    source = re.sub(r"//[^\n]*", "", source)
    return dict(re.findall(r"\.(\w+)\s*=\s*([^\n]+?),?\s*$", source, re.MULTILINE))


def rgb(value, palette, fallback):
    value = value.rstrip(",").strip()
    if value == ".default":
        return fallback
    if match := re.fullmatch(r"rgb24c?\((0x[0-9a-fA-F]+)\)", value):
        return int(match[1], 16)
    if match := re.fullmatch(r"rgb\((\d+),\s*(\d+),\s*(\d+)\)", value):
        red, green, blue = map(int, match.groups())
        return red << 16 | green << 8 | blue
    if match := re.fullmatch(r"indexed\((\d+)\)", value):
        return palette[int(match[1])]
    raise ValueError(f"Unsupported theme color: {value}")


def main():
    source_path, output_path = map(pathlib.Path, sys.argv[1:])
    source = source_path.read_text()
    chrome_source, _ = balanced(
        source, source.index("{", source.index(".palette = switch"))
    )
    chrome = blocks(chrome_source)
    terminal = blocks(source[source.index("fn terminal(") : source.index("fn ansi(")])
    shade_start = source.index(".shade => builtin(.vesper).withOverrides(.{")
    shade_body, _ = balanced(source, source.index("{", shade_start))
    names = [
        "shade",
        "vesper",
        "catppuccin",
        "tokyo_night",
        "pierre_dark",
        "pierre_dark_soft",
        "kanagawa",
        "kanagawa_dragon",
        "terminal",
        "cybervenom",
    ]
    defaults = source_path.with_name("TerminalTheme.zig").read_text()
    default_palette_body, _ = balanced(
        defaults, defaults.index("{", defaults.index("palette:"))
    )
    default_palette = []
    for channels in re.findall(r"\.\{([^{}]+)\}", default_palette_body):
        red, green, blue = map(int, channels.split(","))
        default_palette.append(red << 16 | green << 8 | blue)

    def default_color(field):
        channels = re.search(rf"{field}: \[3\]u8 = \.\{{([^}}]+)\}}", defaults)
        red, green, blue = map(int, channels[1].split(","))
        return red << 16 | green << 8 | blue

    syntax_source = source[source.index("fn syntax(") : source.index("fn terminal(")]
    syntax_cases = dict(re.findall(r"\.(\w+) => \.\{([^}]+)\}", syntax_source))
    palette_fields = re.findall(
        r"^(\w+): cellgrid.Color",
        source_path.with_name("Palette.zig").read_text(),
        re.MULTILINE,
    )
    syntax_roles = re.findall(
        r"\.(\w+)", re.search(r"const roles = \.\{([^}]+)\}", syntax_source)[1]
    )
    output = [
        "",
        "",
        "namespace telar::gui {",
        "",
        "struct ThemePreset {",
        "  std::string_view name;",
        "  ThemeValues values;",
        "};",
        "",
        f"inline constexpr std::array<ThemePreset, {len(names)}> theme_presets{{{{",
    ]

    def color_value(value):
        value = value.rstrip(",").strip()
        if value == ".default":
            return "{}"
        if match := re.fullmatch(r"indexed\((\d+)\)", value):
            return (
                "{.kind = CellColor::Kind::indexed, .channels = {"
                + match[1]
                + ", 0, 0}}"
            )
        return (
            "{.kind = CellColor::Kind::rgb, .channels = "
            + rgb_bytes(rgb(value, default_palette, 0))
            + "}"
        )

    def rgb_bytes(value):
        return (
            "{" + ", ".join(str((value >> shift) & 255) for shift in (16, 8, 0)) + "}"
        )

    for name in names:
        terminal_body = terminal[name]
        terminal_body = re.sub(
            r"if \(name == \.pierre_dark\) (0x[0-9a-f]+) else (0x[0-9a-f]+)",
            lambda match: match[1] if name == "pierre_dark" else match[2],
            terminal_body,
        )
        values = assignments(terminal_body)
        palette_match = re.search(
            r"\.palette = ansi\(\.\{(.*?)\}\)", terminal_body, re.DOTALL
        )
        palette = (
            [int(value, 16) for value in re.findall(r"0x[0-9a-f]+", palette_match[1])]
            if palette_match
            else default_palette
        )
        if len(palette) != 16:
            raise ValueError(f"Invalid ANSI palette: {name}")

        chrome_values = assignments(
            chrome["vesper"] if name == "shade" else chrome[name]
        )
        if name == "shade":
            chrome_values.update(assignments(shade_body))
        output.extend(
            [
                "  {",
                f'    "{name.replace("_", "-")}",',
                "    {",
                f"      .base = ThemeName::{name},",
                "      .palette = {{",
            ]
        )
        for field in palette_fields:
            output.append("        " + color_value(chrome_values[field]) + ",")
        output.extend(["      }},", "      .terminal = {"])
        for field in ("foreground", "background", "cursor_color", "cursor_text_color"):
            if field in values:
                expression = rgb_bytes(rgb(values[field], palette, 0))
                if field.startswith("cursor_"):
                    expression = "ThemeRgb" + expression
            elif field in ("foreground", "background"):
                expression = rgb_bytes(default_color(field))
            else:
                expression = "std::nullopt"
            output.append(f"        .{field} = {expression},")
        output.append("        .palette = {{")
        for color in palette:
            output.append("          " + rgb_bytes(color) + ",")
        output.extend(["        }},", "      },", "      .syntax_styles = {{"])
        colors = re.findall(r"0x[0-9a-f]+|\bnull\b", syntax_cases.get(name, ""))
        if colors and len(colors) != len(syntax_roles):
            raise ValueError(f"Invalid syntax palette: {name}")
        for index, role in enumerate(syntax_roles):
            if not colors or colors[index] == "null":
                output.append("        std::nullopt,")
                continue
            italic = (name == "shade" and role == "parameter") or (
                name in ("kanagawa", "kanagawa_dragon")
                and role in ("keyword", "comment")
            )
            color = color_value(f"rgb24c({colors[index]})")
            output.append(
                "        SyntaxStyleValues{.color = "
                + color
                + ", .italic = "
                + str(italic).lower()
                + "},"
            )
        output.extend(["      }},", "    },", "  },"])

    default_name = re.search(r"pub const default_theme = builtin\(\.(\w+)\);", source)[1]
    default_index = names.index(default_name)
    output.extend([
        "}};",
        "",
        f"inline constexpr ThemeValues default_theme_values = theme_presets[{default_index}].values;",
        "",
        "}",
        "",
    ])
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(output))


if __name__ == "__main__":
    main()
