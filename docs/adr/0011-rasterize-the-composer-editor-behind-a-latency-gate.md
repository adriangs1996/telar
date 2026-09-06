---
status: accepted
---

# Rasterize the composer editor behind a latency gate

The graphics invariant says cells keep every function and KGP only enriches.
The composer, where the user writes prompts to agents, is the one surface
where the review chose typography over that rule: proportional type, a
markdown preview and inline thumbnails, the way T3 Code's composer looks.

## Decision

The composer keeps one text model (`text_area`) and two renderers. The cell
renderer ships first and stays as the fallback. The raster renderer draws the
prompt as one KGP image per visual line, with a caret and a selection that
telar owns, shaped with HarfBuzz from an embedded proportional face for prose
and JetBrains Mono for code.

This is the first place where the visible echo of a keystroke passes through
the media path. It is an explicit, recorded exception to the interactive-path
rule, guarded by a gate: the benchmark must show a one-line echo (raster,
encode, placement) at p99 under one pacer interval on the local transport,
and a session that misses it falls back to the cell renderer while the pane
never waits. Remote clients over SSH always get the cell renderer. IME
composition text has no preedit rendering; the terminal cursor is hidden
while composing and the caret is an image.

## Considered options

- Hybrid only (cells own the text, KGP paints frame, chips, meter,
  thumbnails): keeps every invariant and the host font, and ships first as
  the fallback. Rejected as the target because the review wanted the
  editor's typography itself.
- Rasterizing the whole agent-mode chrome: rejected; only the composer
  crosses the line, and the conversation view stays hybrid (cells over KGP)
  unless a later experiment says otherwise.

## Consequences

- A text layout engine, own selection and copy, and a second embedded font
  enter the client. The font seam between the composer and the agent's pane
  is accepted on purpose.
- The gate is the completion criterion of the phase that builds it; failing
  it leaves the composer hybrid, not broken.
- `docs/engineering-invariants.md` records the exception and the fallback
  rule beside the interactive-path rules.
