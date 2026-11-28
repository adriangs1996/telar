#!/usr/bin/env python3
"""Generate the Chrome themes and the Stylus userstyles of Transylvania from the GUI's presets.

The colors live once, in src/gui/features/configuration/configuration-themes.cppm. Run this after
changing a Transylvania preset; --check fails when a generated file is out of date."""
import argparse
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PRESETS = ROOT / 'src/gui/features/configuration/configuration-themes.cppm'
VERSION = '1.0.0'
NAMESPACE = 'github.com/adriangs1996/telar'

# Variant, its preset in the GUI and its name in the browsers. Luna is the first: the default.
VARIANTS = (
    ('luna', 'transylvania', 'Luna'),
    ('vela', 'transylvania-vela', 'Vela'),
    ('sangre', 'transylvania-sangre', 'Sangre'),
)
# The order of lib/config/gui/gui.cppm's theme_color_names and theme_syntax_names.
COLOR_NAMES = ('accent', 'panel_bg', 'surface0', 'surface1', 'surface_dim', 'overlay0', 'overlay1', 'text',
               'subtext0', 'mauve', 'green', 'yellow', 'red', 'blue', 'teal', 'peach')
SYNTAX_NAMES = ('plain', 'keyword', 'string', 'number', 'comment', 'constant', 'builtin_constant', 'builtin',
                'func', 'type', 'parameter', 'property', 'namespace', 'operator', 'punctuation')
CHANNELS = re.compile(r'\{(\d+), (\d+), (\d+)\}')


def preset_block(source, name):
    start = source.index(f'.name = "{name}"')
    end = source.find('ThemePreset{', start)
    return source[start:end if end >= 0 else len(source)]


def section(block, marker, closing):
    start = block.index(marker)
    return block[start:block.index(closing, start)]


def rgbs(text, count):
    found = [tuple(int(c) for c in m.groups()) for m in CHANNELS.finditer(text)]
    if len(found) != count:
        sys.exit(f'expected {count} colors, found {len(found)}')
    return found


def read_variant(source, preset):
    block = preset_block(source, preset)
    colors = dict(zip(COLOR_NAMES, rgbs(section(block, '.palette = {', '.terminal = {'), 16)))
    terminal = section(block, '.terminal = {', '.syntax_styles = {')
    # Foreground, background, cursor and cursor text come before the 16 ANSI colors.
    ansi = rgbs(terminal, 20)[4:]
    syntax = dict(zip(SYNTAX_NAMES, rgbs(block[block.index('.syntax_styles = {'):], 15)))
    return {**colors, 'magenta': ansi[5], 'syntax': syntax}


def hexa(rgb):
    return '#%02x%02x%02x' % rgb


def chrome_manifest(label, v):
    c = lambda key: list(v[key])
    dim, comment = c('surface_dim'), list(v['syntax']['comment'])
    colors = {
        'frame': dim, 'frame_inactive': dim, 'frame_incognito': dim, 'frame_incognito_inactive': dim,
        'background_tab': dim, 'background_tab_inactive': dim,
        'background_tab_incognito': dim, 'background_tab_incognito_inactive': dim,
        'toolbar': c('surface0'), 'toolbar_text': c('text'), 'toolbar_button_icon': c('accent'),
        'tab_text': c('text'), 'tab_background_text': c('subtext0'), 'tab_background_text_inactive': comment,
        'tab_background_text_incognito': c('subtext0'), 'tab_background_text_incognito_inactive': comment,
        'bookmark_text': c('subtext0'),
        'omnibox_background': c('panel_bg'), 'omnibox_text': c('text'),
        'ntp_background': c('panel_bg'), 'ntp_text': c('text'), 'ntp_link': c('accent'), 'ntp_header': c('surface0'),
    }
    return {
        'manifest_version': 3,
        'name': f'Transylvania {label}',
        'version': VERSION,
        'description': f'Telar\'s Transylvania {label} theme for Chrome.',
        'theme': {'colors': colors},
    }


# The custom properties both userstyles read, per variant.
def less_variables(v):
    s = v['syntax']
    props = {
        'bg': v['panel_bg'], 'bg-dim': v['surface_dim'], 'surface0': v['surface0'], 'surface1': v['surface1'],
        'overlay0': v['overlay0'], 'overlay1': v['overlay1'], 'text': v['text'], 'subtext': v['subtext0'],
        'accent': v['accent'], 'green': v['green'], 'yellow': v['yellow'], 'red': v['red'], 'teal': v['teal'],
        'peach': v['peach'], 'magenta': v['magenta'],
        'syntax-keyword': s['keyword'], 'syntax-string': s['string'], 'syntax-number': s['number'],
        'syntax-comment': s['comment'], 'syntax-builtin': s['builtin'], 'syntax-func': s['func'],
        'syntax-parameter': s['parameter'], 'syntax-property': s['property'], 'syntax-namespace': s['namespace'],
        'syntax-operator': s['operator'],
    }
    return ''.join(f'  --tr-{k}: {hexa(rgb)};\n' for k, rgb in props.items())


def userstyle(name, description, extra_vars, body, variants):
    options = ', '.join(f'"{key}:{label}{"*" if i == 0 else ""}": "{key}"'
                        for i, (key, _, label) in enumerate(VARIANTS))
    mixins = ''.join(f'.transylvania({key}) {{\n{less_variables(variants[key])}}}\n' for key, _, _ in VARIANTS)
    return f'''/* ==UserStyle==
@name         {name}
@namespace    {NAMESPACE}
@version      {VERSION}
@description  {description}
@author       Adrian Gonzalez
@license      MIT
@homepageURL  https://{NAMESPACE}
@preprocessor less
@var select variant "Variant" {{{options}}}
{extra_vars}==/UserStyle== */

/* Generated by extras/transylvania/generate.py from Telar's presets. Do not edit. */

{mixins}
{body}'''


GLOBAL_VARS = '''@var checkbox selection "Selection" 1
@var checkbox scrollbars "Scrollbars" 1
@var checkbox controls "Form controls" 1
'''

GLOBAL_BODY = '''html { .transylvania(@variant); }

& when (@selection = 1) {
  ::selection { background-color: color-mix(in srgb, var(--tr-accent) 40%, transparent); }
}

& when (@scrollbars = 1) {
  html { scrollbar-color: var(--tr-surface1) var(--tr-bg-dim); }
}

& when (@controls = 1) {
  html { accent-color: var(--tr-accent); }
}
'''

# Primer's functional tokens. Tokens Primer derives with var() follow these, so only the roots and
# the tokens Primer sets to a literal are overridden. The legacy --color-* names cover older pages.
GITHUB_BODY = '''@-moz-document domain("github.com"), domain("gist.github.com") {
  :root, [data-color-mode] {
    .transylvania(@variant);
    color-scheme: dark !important;

    --bgColor-default: var(--tr-bg) !important;
    --bgColor-muted: var(--tr-surface0) !important;
    --bgColor-inset: var(--tr-bg-dim) !important;
    --bgColor-emphasis: var(--tr-surface1) !important;
    --bgColor-inverse: var(--tr-text) !important;
    --bgColor-disabled: var(--tr-surface0) !important;
    --bgColor-neutral-muted: color-mix(in srgb, var(--tr-overlay1) 20%, transparent) !important;
    --bgColor-neutral-emphasis: var(--tr-overlay1) !important;
    --bgColor-accent-muted: color-mix(in srgb, var(--tr-accent) 15%, transparent) !important;
    --bgColor-accent-emphasis: var(--tr-accent) !important;
    --bgColor-success-muted: color-mix(in srgb, var(--tr-green) 15%, transparent) !important;
    --bgColor-success-emphasis: var(--tr-green) !important;
    --bgColor-open-muted: color-mix(in srgb, var(--tr-green) 15%, transparent) !important;
    --bgColor-open-emphasis: var(--tr-green) !important;
    --bgColor-attention-muted: color-mix(in srgb, var(--tr-yellow) 15%, transparent) !important;
    --bgColor-attention-emphasis: var(--tr-yellow) !important;
    --bgColor-severe-muted: color-mix(in srgb, var(--tr-peach) 15%, transparent) !important;
    --bgColor-severe-emphasis: var(--tr-peach) !important;
    --bgColor-danger-muted: color-mix(in srgb, var(--tr-red) 15%, transparent) !important;
    --bgColor-danger-emphasis: var(--tr-red) !important;
    --bgColor-closed-muted: color-mix(in srgb, var(--tr-red) 15%, transparent) !important;
    --bgColor-closed-emphasis: var(--tr-red) !important;
    --bgColor-done-muted: color-mix(in srgb, var(--tr-magenta) 15%, transparent) !important;
    --bgColor-done-emphasis: var(--tr-magenta) !important;
    --bgColor-sponsors-muted: color-mix(in srgb, var(--tr-magenta) 15%, transparent) !important;
    --bgColor-sponsors-emphasis: var(--tr-magenta) !important;
    --bgColor-draft-muted: color-mix(in srgb, var(--tr-overlay1) 15%, transparent) !important;
    --bgColor-draft-emphasis: var(--tr-overlay1) !important;

    --fgColor-default: var(--tr-text) !important;
    --fgColor-muted: var(--tr-subtext) !important;
    --fgColor-disabled: var(--tr-syntax-comment) !important;
    --fgColor-onEmphasis: var(--tr-bg) !important;
    --fgColor-onInverse: var(--tr-bg) !important;
    --fgColor-accent: var(--tr-accent) !important;
    --fgColor-link: var(--tr-accent) !important;
    --fgColor-neutral: var(--tr-subtext) !important;
    --fgColor-success: var(--tr-green) !important;
    --fgColor-open: var(--tr-green) !important;
    --fgColor-attention: var(--tr-yellow) !important;
    --fgColor-severe: var(--tr-peach) !important;
    --fgColor-danger: var(--tr-red) !important;
    --fgColor-closed: var(--tr-red) !important;
    --fgColor-done: var(--tr-magenta) !important;
    --fgColor-sponsors: var(--tr-magenta) !important;
    --fgColor-draft: var(--tr-subtext) !important;

    --borderColor-default: var(--tr-surface1) !important;
    --borderColor-muted: var(--tr-overlay0) !important;
    --borderColor-emphasis: var(--tr-overlay1) !important;
    --borderColor-disabled: var(--tr-overlay0) !important;
    --borderColor-translucent: color-mix(in srgb, var(--tr-overlay1) 30%, transparent) !important;
    --borderColor-neutral-muted: var(--tr-overlay0) !important;
    --borderColor-neutral-emphasis: var(--tr-overlay1) !important;
    --borderColor-accent-muted: color-mix(in srgb, var(--tr-accent) 40%, transparent) !important;
    --borderColor-accent-emphasis: var(--tr-accent) !important;
    --borderColor-success-muted: color-mix(in srgb, var(--tr-green) 40%, transparent) !important;
    --borderColor-success-emphasis: var(--tr-green) !important;
    --borderColor-open-muted: color-mix(in srgb, var(--tr-green) 40%, transparent) !important;
    --borderColor-open-emphasis: var(--tr-green) !important;
    --borderColor-attention-muted: color-mix(in srgb, var(--tr-yellow) 40%, transparent) !important;
    --borderColor-attention-emphasis: var(--tr-yellow) !important;
    --borderColor-severe-muted: color-mix(in srgb, var(--tr-peach) 40%, transparent) !important;
    --borderColor-severe-emphasis: var(--tr-peach) !important;
    --borderColor-danger-muted: color-mix(in srgb, var(--tr-red) 40%, transparent) !important;
    --borderColor-danger-emphasis: var(--tr-red) !important;
    --borderColor-closed-muted: color-mix(in srgb, var(--tr-red) 40%, transparent) !important;
    --borderColor-closed-emphasis: var(--tr-red) !important;
    --borderColor-done-muted: color-mix(in srgb, var(--tr-magenta) 40%, transparent) !important;
    --borderColor-done-emphasis: var(--tr-magenta) !important;

    --control-bgColor-rest: var(--tr-surface0) !important;
    --control-bgColor-hover: var(--tr-surface1) !important;
    --control-bgColor-active: var(--tr-surface1) !important;
    --control-borderColor-rest: var(--tr-surface1) !important;
    --control-checked-bgColor-rest: var(--tr-accent) !important;
    --control-checked-bgColor-hover: color-mix(in srgb, var(--tr-accent) 85%, var(--tr-text)) !important;
    --control-checked-bgColor-active: color-mix(in srgb, var(--tr-accent) 85%, var(--tr-text)) !important;
    --control-checked-borderColor-rest: var(--tr-accent) !important;
    --control-checked-fgColor-rest: var(--tr-bg) !important;
    --button-default-bgColor-hover: var(--tr-surface1) !important;
    --button-default-bgColor-active: var(--tr-surface1) !important;
    --button-default-borderColor-rest: var(--tr-surface1) !important;
    --button-primary-bgColor-rest: var(--tr-accent) !important;
    --button-primary-bgColor-hover: color-mix(in srgb, var(--tr-accent) 85%, var(--tr-text)) !important;
    --button-primary-bgColor-active: color-mix(in srgb, var(--tr-accent) 85%, var(--tr-text)) !important;
    --button-primary-bgColor-disabled: color-mix(in srgb, var(--tr-accent) 40%, var(--tr-bg)) !important;
    --button-primary-borderColor-rest: transparent !important;
    --button-primary-fgColor-rest: var(--tr-bg) !important;
    --button-primary-iconColor-rest: var(--tr-bg) !important;

    --header-bgColor: var(--tr-bg-dim) !important;
    --header-fgColor-default: var(--tr-text) !important;
    --header-fgColor-logo: var(--tr-text) !important;
    --headerSearch-bgColor: var(--tr-bg) !important;
    --headerSearch-borderColor: var(--tr-surface1) !important;
    --overlay-bgColor: var(--tr-surface0) !important;
    --overlay-borderColor: var(--tr-surface1) !important;
    --tooltip-bgColor: var(--tr-surface1) !important;
    --tooltip-fgColor: var(--tr-text) !important;
    --selection-bgColor: color-mix(in srgb, var(--tr-accent) 35%, transparent) !important;
    --focus-outline-color: var(--tr-accent) !important;
    --underlineNav-borderColor-active: var(--tr-accent) !important;
    --timelineBadge-bgColor: var(--tr-surface1) !important;

    --contribution-default-bgColor-0: var(--tr-surface0) !important;
    --contribution-default-bgColor-1: color-mix(in srgb, var(--tr-accent) 30%, var(--tr-surface0)) !important;
    --contribution-default-bgColor-2: color-mix(in srgb, var(--tr-accent) 55%, var(--tr-surface0)) !important;
    --contribution-default-bgColor-3: color-mix(in srgb, var(--tr-accent) 80%, var(--tr-surface0)) !important;
    --contribution-default-bgColor-4: var(--tr-accent) !important;

    --diffBlob-hunkLine-bgColor: color-mix(in srgb, var(--tr-accent) 10%, transparent) !important;
    --diffBlob-hunkLine-fgColor: var(--tr-subtext) !important;
    --diffBlob-hunkNum-bgColor-rest: color-mix(in srgb, var(--tr-accent) 20%, transparent) !important;
    --diffBlob-additionWord-bgColor: color-mix(in srgb, var(--tr-green) 35%, transparent) !important;
    --diffBlob-additionNum-bgColor: color-mix(in srgb, var(--tr-green) 25%, transparent) !important;
    --diffBlob-deletionWord-bgColor: color-mix(in srgb, var(--tr-red) 35%, transparent) !important;
    --diffBlob-deletionNum-bgColor: color-mix(in srgb, var(--tr-red) 25%, transparent) !important;

    --color-prettylights-syntax-comment: var(--tr-syntax-comment) !important;
    --color-prettylights-syntax-keyword: var(--tr-syntax-keyword) !important;
    --color-prettylights-syntax-string: var(--tr-syntax-string) !important;
    --color-prettylights-syntax-string-regexp: var(--tr-syntax-builtin) !important;
    --color-prettylights-syntax-constant: var(--tr-syntax-number) !important;
    --color-prettylights-syntax-constant-other-reference-link: var(--tr-syntax-string) !important;
    --color-prettylights-syntax-entity: var(--tr-syntax-func) !important;
    --color-prettylights-syntax-entity-tag: var(--tr-syntax-builtin) !important;
    --color-prettylights-syntax-variable: var(--tr-syntax-parameter) !important;
    --color-prettylights-syntax-storage-modifier-import: var(--tr-syntax-namespace) !important;
    --color-prettylights-syntax-brackethighlighter-angle: var(--tr-syntax-operator) !important;
    --color-prettylights-syntax-brackethighlighter-unmatched: var(--tr-red) !important;
    --color-prettylights-syntax-invalid-illegal-text: var(--tr-bg) !important;
    --color-prettylights-syntax-invalid-illegal-bg: var(--tr-red) !important;
    --color-prettylights-syntax-carriage-return-text: var(--tr-bg) !important;
    --color-prettylights-syntax-carriage-return-bg: var(--tr-red) !important;
    --color-prettylights-syntax-markup-heading: var(--tr-accent) !important;
    --color-prettylights-syntax-markup-list: var(--tr-yellow) !important;
    --color-prettylights-syntax-markup-bold: var(--tr-text) !important;
    --color-prettylights-syntax-markup-italic: var(--tr-text) !important;
    --color-prettylights-syntax-markup-inserted-text: var(--tr-green) !important;
    --color-prettylights-syntax-markup-inserted-bg: color-mix(in srgb, var(--tr-green) 15%, transparent) !important;
    --color-prettylights-syntax-markup-deleted-text: var(--tr-red) !important;
    --color-prettylights-syntax-markup-deleted-bg: color-mix(in srgb, var(--tr-red) 15%, transparent) !important;
    --color-prettylights-syntax-markup-changed-text: var(--tr-peach) !important;
    --color-prettylights-syntax-markup-changed-bg: color-mix(in srgb, var(--tr-peach) 15%, transparent) !important;
    --color-prettylights-syntax-markup-ignored-text: var(--tr-text) !important;
    --color-prettylights-syntax-markup-ignored-bg: var(--tr-surface1) !important;
    --color-prettylights-syntax-meta-diff-range: var(--tr-magenta) !important;
    --color-prettylights-syntax-sublimelinter-gutter-mark: var(--tr-overlay1) !important;

    --color-canvas-default: var(--tr-bg) !important;
    --color-canvas-subtle: var(--tr-surface0) !important;
    --color-canvas-inset: var(--tr-bg-dim) !important;
    --color-canvas-overlay: var(--tr-surface0) !important;
    --color-fg-default: var(--tr-text) !important;
    --color-fg-muted: var(--tr-subtext) !important;
    --color-fg-on-emphasis: var(--tr-bg) !important;
    --color-accent-fg: var(--tr-accent) !important;
    --color-accent-emphasis: var(--tr-accent) !important;
    --color-border-default: var(--tr-surface1) !important;
    --color-border-muted: var(--tr-overlay0) !important;
  }

  /* Comments and parameters are italic, as in Telar. */
  .pl-c, .pl-v { font-style: italic; }
}
'''


def outputs():
    source = PRESETS.read_text()
    variants = {key: read_variant(source, preset) for key, preset, _ in VARIANTS}
    files = {}
    for key, _, label in VARIANTS:
        manifest = json.dumps(chrome_manifest(label, variants[key]), indent=2)
        # One color per line: [r, g, b].
        manifest = re.sub(r'\[\s*(\d+),\s*(\d+),\s*(\d+)\s*\]', r'[\1, \2, \3]', manifest)
        files[f'chrome/{key}/manifest.json'] = manifest + '\n'
    files['stylus/transylvania.user.css'] = userstyle(
        'Transylvania', 'Transylvania Luna, Vela or Sangre for the selection, scrollbars and form controls of every site.',
        GLOBAL_VARS, GLOBAL_BODY, variants)
    files['stylus/transylvania-github.user.css'] = userstyle(
        'Transylvania for GitHub', 'GitHub in Transylvania Luna, Vela or Sangre.', '', GITHUB_BODY, variants)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail when a generated file is out of date')
    args = parser.parse_args()
    stale = []
    for path, text in outputs().items():
        target = HERE / path
        if target.exists() and target.read_text() == text:
            continue
        if args.check:
            stale.append(path)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        print(f'wrote {path}')
    if stale:
        sys.exit('out of date, run extras/transylvania/generate.py: ' + ', '.join(stale))


if __name__ == '__main__':
    main()
