# telar.dev

Landing page for telar. Next.js with Tailwind CSS.

```sh
npm install
npm run dev
```

The page is one telar client window on a desk: a top bar with tabs, a live
sidebar of agent sessions, a bottom bar with the active keys, and every section
as a numbered pane. The window stays pinned while the page scrolls one step per
pane; panes of the same tab sit side by side and slide horizontally. `j/k` walk
the panes, `h/l` move inside a tab, `1-8` jump, `z` fullscreens the window, `/`
opens the history palette, `?` lists the keys. "Kill this client" in pane 3
detaches the whole page and "Attach a client" redraws it. The hero embroiders
the word telar on the warp in satin stitch, one letter per second.

- `lib/panes.ts` is the pane and tab registry.
- `lib/agents.ts` holds the agent cards and the scripted activity after attach.
- `components/client/` is the client: provider, chrome, panes, overlays.
- `components/sections/` is the content of each pane.

`npm run build` produces a fully static page.

## Brand

`public/brand/` holds the icon: `telar-icon.svg` (app, 48 px and up),
`telar-icon-small.svg` (favicon and sidebar, 32 px and below), the one-color
`telar-mark*.svg`, and PNG renders at 1024 and 512. `app/icon.svg` and
`app/apple-icon.png` are what Next.js serves as favicons. The working files
for the design canvas live in `brand/icon/`.
