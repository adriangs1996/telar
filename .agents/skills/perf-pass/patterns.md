# Patterns

Reuse the shape, re-prove the equivalence.

## Layout

- **Hot/cold split.** Put what every iteration reads in a dense array and
  move the rest to a parallel one, so a warm pass touches only the hot
  stride and a flag tells it when to skip the cold data.
- **Dense keys.** Search a compact key array plus an occupancy bit set, not
  the aggregates; a lookup that scans whole slots pays their full size per
  probe.
- **Row views.** Take a row `std::span` once and iterate it, instead of
  computing an index and a bounds check per element.

## Comparison

- **Canonical representation.** Make every byte defined (trivially copyable
  structs, constructors that zero unused bytes, no padding) so equality is a
  byte compare. `static_assert(std::has_unique_object_representations_v<T>)`.
  Byte equality must imply value equality; the reverse only costs redundant
  work.
- **Compare in place.** Mutating a copy of an element splits it into scalars;
  compare against the source and copy only the elements that change.

## Retained work

- **Content-keyed caches.** Key on a fingerprint of the content plus every
  layout input (width, font identity and revision, metrics, flags). Exclude
  entries whose result depends on outside state. Test cached against fresh
  through the changes the key must catch.
- **Fast path, same arithmetic.** A shortcut for the common case (one-byte
  ASCII glyphs) reuses the exact formulas of the general path, and a test
  compares both over the whole small domain.
- **Reserved runs.** When the worst case of a run fits the buffer and the
  budget, write without per-element checks; fall back otherwise. Identical
  bytes either way.
- **Memoize by stable id** within a scope where the id is proven stable (one
  style id per row in a VT page).

## Formatting and copies

- Format integers with `std::to_chars` into the writer's unused span instead
  of `std::format`; fall back to the general path near a full buffer.
- Replace per-element variable-length copies with whole-element stores only
  if the paired run agrees: the change alters loop codegen and can regress
  sparse work.

## Correctness first

A pass also fixes correctness bugs it finds, each with a regression test that
fails on the old code. Gains that change semantics (sampling `tcgetpgrp`
elsewhere) are reported with their measured cost and left for the user.
