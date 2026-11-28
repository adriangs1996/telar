# Transylvania for the browser

Telar's Transylvania themes, Luna, Vela and Sangre, for Chrome and for
[Stylus](https://github.com/openstyles/stylus). `generate.py` writes every file here from the
`transylvania`, `transylvania-vela` and `transylvania-sangre` presets in
`src/gui/features/configuration/configuration-themes.cppm`, so do not edit them by hand. After
changing a preset, run:

```sh
extras/transylvania/generate.py          # rewrite the files
extras/transylvania/generate.py --check  # fail if a file is out of date
```

## Chrome

`chrome/luna`, `chrome/vela` and `chrome/sangre` are theme extensions. In `chrome://extensions`,
turn on Developer mode, choose "Load unpacked" and select one of the three folders. Chrome keeps
one theme at a time; loading another replaces it, and "Reset to default" in
`chrome://settings/appearance` removes it.

The frame and the inactive tabs take the theme's dimmest surface, the toolbar and the active tab
its `surface0`, the address bar and the new tab page its background, and the toolbar icons and
new tab links its accent.

## Stylus

Open a `.user.css` file in the browser with Stylus installed, or paste it into a new style in
Stylus's manager. Each style chooses the variant in its options.

- `stylus/transylvania.user.css` applies to every site and leaves each page's own colors alone. It
  paints the text selection, the scrollbars and the form controls (`accent-color`) in
  Transylvania. Each of the three can be turned off.
- `stylus/transylvania-github.user.css` repaints github.com and gist.github.com, in GitHub's light
  or dark mode, by overriding the Primer color tokens: canvas, text, borders, buttons, labels, diffs,
  the contribution graph and the code highlighting, with comments and parameters in italic as in
  Telar.

Both use Stylus's Less preprocessor.
