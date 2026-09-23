# Patterns

Each pattern names where it paid off in telar; reuse the shape, re-prove the
equivalence.

## Layout

- **Hot/cold split.** Put what every iteration reads in a dense array and
  move the rest to a parallel one. Retained GUI cells keep background plus
  first ink quad (160 B stride) apart from 22 overflow quads; metadata carries
  a `background` flag so warm draws skip geometry entirely.
- **Dense keys.** Search a compact key array plus an occupancy bit set, not
  the aggregates. `agent.Repository` scanned 64 × 8,360 B slots per lookup.
- **Row views.** Take a row slice once and iterate it, instead of computing an
  index and a bounds check per element.

## Comparison

- **Canonical representation.** Make every byte defined (extern structs,
  constructors that zero unused bytes, no padding) so equality is a byte
  compare. Assert `std.meta.hasUniqueRepresentation` at comptime. Byte
  equality must imply value equality; the reverse only costs redundant work.
- **Compare in place.** Mutating a copy of an element splits it into scalars;
  compare against the source pointer and copy only the elements that change.

## Retained work

- **Content-keyed caches.** Key on a fingerprint of the content plus every
  layout input (width, font identity and revision, metrics, flags). Exclude
  entries whose result depends on outside state (message heights skip
  anything mentioning `mermaid`). Test cached against fresh through the
  changes the key must catch.
- **Fast path, same arithmetic.** A shortcut for the common case (one-byte
  ASCII glyphs) reuses the exact formulas of the general path, and a test
  compares both over the whole small domain.
- **Reserved runs.** When the worst case of a run fits the buffer and the
  budget, write without per-element checks; fall back otherwise. Identical
  bytes either way.
- **Memoize by stable id** within a scope where the id is proven stable (one
  style id per row in a VT page).

## Formatting and copies

- Format integers into the writer's unused slice instead of `std.fmt`; fall
  back to `print` near a full buffer.
- Replace per-element variable-length copies with whole-element stores only
  if the paired run agrees; it changed loop codegen and regressed sparse
  draws once.

## Correctness first

A pass also fixes correctness bugs it finds (the unbounded tombstone loop in
`GenericSlotIndex`), each with a regression test that fails on the old code.
Gains that change semantics (sampling `tcgetpgrp` elsewhere) are reported
with their measured cost and left for the user.
