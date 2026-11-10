#!/usr/bin/env python3
"""Embeds the completion specs telar ships into a C++ header.

The specs are the EBNF files in lib/ebnf/specs, plus one for telar itself, written here
from the CLI's help files so it never drifts from the commands the binary has: each
family and command with its description, and each option its usage line names, with the
description its Arguments section gives.
"""

import argparse
import pathlib
import re
import sys

ENTRY = re.compile(r"^  (\S.*?)(?:\s{2,}(.*))?$")
HEADER = re.compile(r"^([A-Z][A-Za-z ]*):\s*$")
OPTION = re.compile(r"(?<![\w-])(--?[A-Za-z][A-Za-z0-9-]*)(?:[ =]((?:[A-Z][A-Z0-9_]*(?:\.\.\.)?)|(?:[a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)+)))?")
PLACEHOLDERS = {
    "PATH": "@file",
    "FILE": "@file",
    "ABS": "@file",
    "ABS_PATH": "@file",
    "DIR": "@directory",
    "N": "@number",
    "MS": "@number",
    "S": "@number",
    "COLUMNS": "@number",
    "LINES": "@number",
    "BRANCH": "@branch",
    "REF": "@branch",
}
# Options many commands share, which their help names only in the usage line.
COMMON = {
    "--json": "Print JSON",
    "--socket": "The runtime's socket",
    "--current": "The pane this runs in",
    "--help": "Show this help",
    "-h": "Show this help",
}
ASCII = {"‘": "'", "’": "'", "“": "'", "”": "'", "–": "-", "—": "-", "…": "...", "·": "-", "→": "->"}


def text(value):
    """A description as a spec literal holds it: printable ASCII, quotes escaped."""
    value = "".join(ASCII.get(character, character) for character in value)
    value = "".join(character for character in value if 32 <= ord(character) < 127)
    value = re.split(r"(?<=[a-z0-9)`'])\. ", value)[0].rstrip(". ")
    value = value.replace("`", "'")
    if len(value) > 100:
        value = value[:97].rstrip() + "..."
    return value.replace("\\", "\\\\").replace('"', '\\"')


def sections(path):
    """The help file's first line, usage lines and indented sections, by heading."""
    lines = path.read_text(encoding="utf-8").splitlines()
    title = lines[0] if lines else ""
    usage = []
    found = {}
    current = None
    in_usage = False
    for line in lines[1:]:
        if line.startswith("Usage:"):
            in_usage = True
            usage.append(line[len("Usage:"):])
            continue
        if in_usage:
            if line.strip() and line.startswith(" "):
                usage.append(line)
                continue
            in_usage = False
        header = HEADER.match(line)
        if header:
            current = found.setdefault(header.group(1), [])
            continue
        if not line.strip():
            continue
        # Prose ends a section; under Families, unindented lines title groups of families.
        if not line.startswith(" "):
            if current is not found.get("Families"):
                current = None
            continue
        if current is None:
            continue
        entry = ENTRY.match(line)
        if entry:
            current.append([entry.group(1), entry.group(2) or ""])
        elif current:
            current[-1][1] += " " + line.strip()
    return title, " ".join(usage), found


def description(title):
    return text(title.split(":", 1)[1].strip()) if ":" in title else ""


def value(placeholder):
    if placeholder is None:
        return None
    if "|" in placeholder:
        return "( " + " | ".join(f'"{choice}"' for choice in placeholder.split("|")) + " )"
    return PLACEHOLDERS.get(placeholder.rstrip("."), "@any")


def options(usage, arguments, known=None):
    """Each option once, in the order the usage names them, with what follows it. Options
    the arguments do not describe take the description `known` gives, as the global ones."""
    known = known or {}
    described = {}
    for term, meaning in arguments:
        for match in OPTION.finditer(term):
            described.setdefault(match.group(1), (match.group(2), text(meaning)))
    found = {}
    for match in OPTION.finditer(usage):
        name = match.group(1)
        if name not in found:
            found[name] = (match.group(2) or described.get(name, (None, ""))[0], described.get(name, (None, ""))[1] or known.get(name, "") or COMMON.get(name, ""))
    for name, (placeholder, meaning) in described.items():
        found.setdefault(name, (placeholder, meaning))
    result = []
    for name, (placeholder, meaning) in found.items():
        literal = f'"{name}"' + (f' : "{meaning}"' if meaning else "")
        follower = value(placeholder)
        result.append(literal + (f" , {follower}" if follower else ""))
    return result


def rule(name):
    return re.sub(r"[^A-Za-z0-9]", "_", name)


def telar_spec(help_dir):
    title, usage, found = sections(help_dir / "telar.txt")
    rules = []
    top = [entry for entry in found.get("Options before COMMAND", []) if entry[0].startswith("-")]
    known = {}
    for term, meaning in top:
        for match in OPTION.finditer(term):
            known.setdefault(match.group(1), text(meaning))
    families = found.get("Families", [])
    alternatives = []
    for family, meaning in families:
        # Families end in _family and commands join their family with __, so `workspace list`
        # and the `workspace-list` family never share a rule.
        family_rule = f"{rule(family)}_family"
        alternatives.append(f'"{family}" : "{text(meaning)}" , {family_rule}')
        family_file = help_dir / f"{family}.txt"
        if not family_file.exists():
            rules.append(f"{family_rule} = {{ @any }} ;")
            continue
        _, family_usage, family_sections = sections(family_file)
        commands = family_sections.get("Commands", [])
        if not commands:
            own = options(family_usage, family_sections.get("Arguments", []), known)
            rules.append(f"{family_rule} = {{ {family_rule}_argument }} ;")
            rules.append(f"{family_rule}_argument =\n    " + "\n  | ".join(own + ["@any"]) + " ;")
            continue
        names = []
        for command, command_meaning in commands:
            for name in command.split(","):
                name = name.strip()
                if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
                    continue
                command_file = help_dir / family / f"{name}.txt"
                body = f"{rule(family)}__{rule(name)}"
                names.append(f'"{name}" : "{text(command_meaning)}" , {{ {body} }}')
                if command_file.exists():
                    _, command_usage, command_sections = sections(command_file)
                    arguments = command_sections.get("Arguments", []) + command_sections.get("Filters", [])
                    own = options(command_usage, arguments, known)
                else:
                    own = []
                rules.append(f"{body} =\n    " + "\n  | ".join(own + ["@any"]) + " ;")
        rules.append(f"{family_rule} =\n    " + "\n  | ".join(names) + " ;")
    head = [
        "(* telar: written at build time from the CLI's help files (src/cli-cpp/help), so it",
        "   lists the families, commands and options of the binary it ships with. *)",
        "",
        "telar = { option } , [ family ] ;",
        "",
        "option =\n    " + "\n  | ".join(options(" ".join(term for term, _ in top), top)) + " ;",
        "",
        "family =\n    " + "\n  | ".join(alternatives) + " ;",
        "",
    ]
    return "\n".join(head) + "\n\n".join(rules) + "\n"


def header(specs):
    entries = []
    for name, source in specs:
        if ")TELAR_SPEC\"" in source:
            sys.exit(f"{name}: the spec holds the raw string's delimiter")
        entries.append(f'    {{"{name}", R"TELAR_SPEC({source})TELAR_SPEC"}},')
    return "\n".join([
        "#pragma once",
        "",
        "// Generated by tools/generate_command_specs.py; do not edit.",
        "#include <array>",
        "#include <string_view>",
        "#include <utility>",
        "",
        "namespace telar::runtime::shipped {",
        "",
        "// The completion specs telar ships, by the command they describe.",
        f"inline constexpr std::array<std::pair<std::string_view, std::string_view>, {len(specs)}> specs{{{{",
        *entries,
        "}};",
        "",
        "}",
        "",
    ])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--specs", type=pathlib.Path, required=True)
    parser.add_argument("--help-dir", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--telar-spec", type=pathlib.Path, help="also write telar's spec here")
    arguments = parser.parse_args()
    specs = [(path.stem, path.read_text(encoding="utf-8")) for path in sorted(arguments.specs.glob("*.ebnf"))]
    telar = telar_spec(arguments.help_dir)
    specs.append(("telar", telar))
    if arguments.telar_spec:
        arguments.telar_spec.write_text(telar, encoding="utf-8")
    generated = header(specs)
    if not arguments.output.exists() or arguments.output.read_text(encoding="utf-8") != generated:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(generated, encoding="utf-8")


if __name__ == "__main__":
    main()
