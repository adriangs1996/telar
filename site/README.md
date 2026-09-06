# telar.dev

Landing page for telar. Next.js with Tailwind CSS.

```sh
npm install
npm run dev
```

The page is a single scroll: hero, four engineering budgets, one live client
window, seven numbered reasons, a comparison against tmux, the build steps
and a footer. Every number on it comes from `docs/` and is labelled with its
source; agent mode is shown as a design decision, not a shipped feature.

- `lib/agents.ts` holds the demo's workspace, agents, pane transcripts and the
  scripted activity that runs after every attach.
- `components/demo/` is the client window: provider, top bar, sidebar, pane,
  bottom bar, toasts and the detached screen. "Kill this client" throws the
  window away while the runtime counters keep moving; "Attach a client"
  repaints it.
- `components/diagrams/` are the moving figures beside each reason.
- `components/sections/` is the page, top to bottom.
- `components/Reveal.tsx` fades a block in when it scrolls into view and starts
  the animations inside it. Everything honours `prefers-reduced-motion`.

The hero loom (`components/Loom.tsx`) embroiders the word telar on the warp in
satin stitch, one letter per second. The chrome theme switcher under the demo
recolours the window only; what runs inside a pane keeps Vesper.

`npm run build` produces a fully static page.

## Brand

`public/brand/` holds the icon: `telar-icon.svg` (app, 48 px and up),
`telar-icon-small.svg` (favicon and sidebar, 32 px and below), the one-color
`telar-mark*.svg`, and PNG renders at 1024 and 512. `app/icon.svg` and
`app/apple-icon.png` are what Next.js serves as favicons. The working files
for the design canvas live in `brand/icon/`.
