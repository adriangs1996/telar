# telar.dev

Landing page for telar. Next.js with Tailwind CSS.

```sh
pnpm install
pnpm dev
```

The landing (`app/page.tsx`) is one scroll built around Telar's mascot, the
weaver: a hero with the mascot holding terminals in its web
(`components/landing/Weaver.tsx`), the runtime and its SSH thread
(`components/landing/RuntimeDiagram.tsx`), a real screenshot of the window,
the documentation topics, the agents, a Lua configuration and the build
steps. Every claim on it is backed by a page of `/docs`. `SiteHeader` and
`SiteFooter` are shared with the docs, and `components/Reveal.tsx` fades a
block in when it scrolls into view. Everything honours
`prefers-reduced-motion`.

The site has one palette, Cybervenom, Telar's default theme: its tokens are
on `:root` in `app/globals.css`, and the brand icons are drawn in it.

`public/screens/window.png` is a capture of the real Telar window, not a
drawing. `scripts/capture.py` regenerates it: it starts an isolated runtime,
opens `telar-gui` on it, starts an agent (without prompting it), an editor
and a shell in three panes, and lets `telar-gui --screenshot` save the
window. Run it from the repository root with built binaries:

```sh
python3 site/scripts/capture.py --telar PATH/TO/telar --gui PATH/TO/telar-gui \
  --out site/public/screens/window.png
```

`pnpm build` produces a fully static site.

## Documentation

`/docs` is the user documentation, in Telar's default Cybervenom theme and
modelled on Ghostty's docs. `lib/docs.ts` is its table of contents: each
page's slug, sidebar group, title and lead. The sidebar, breadcrumbs, page
heading and `<title>` all read it. Page bodies are MDX in
`content/docs/<slug>.mdx` (the overview is `index.mdx`); `app/docs/[slug]`
renders them. To add a page, add its entry to `lib/docs.ts` and its file to
`content/docs/`. MDX pages can use `<Note>`, `<Tip>` and `<Warning>`
(`mdx-components.tsx`). Each page's content was checked against the C++
sources; keep it that way when behavior changes.

## Brand

`public/brand/` holds the icon: `telar-icon.svg` (the weaver in her web,
128 px and up), `telar-icon-small.svg` (the weaver alone, favicon and
sidebar, 64 px and below), the one-color `telar-mark*.svg`, and PNG renders
at 1024 and 512. `app/icon.svg` and `app/apple-icon.png` are what Next.js
serves as favicons. They are copies: `tools/build_brand_icons.py` writes
them from the sources in `assets/`. `brand/icon/` keeps the working
files of the previous loom icon's design canvas.
