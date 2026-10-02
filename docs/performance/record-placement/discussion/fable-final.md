# Fable, final

ACCEPTED. I read `docs/plans/memory-design-agreement.md` (162 lines) and
`docs/performance/record-placement/README.md`. Both state my positions and my
numbers correctly, including the limits: fixture evidence, mechanism
unconfirmed, no churn, no Linux or x86-64, wrapper selects by size and
alignment rather than by type.

One addition, not a disagreement. Segment size per pool is an unselected
parameter and the agreement does not name it:

- It sets the minimum charge of the first admission, because a segment is
  charged in full. Eight `Pane` slots are about 6.7 MB for the first pane.
- It sets the release granularity: larger segments empty less often.
- A one-record segment is today's behaviour, one page-aligned record per
  mapping, which is the placement that measured slowest.

Suggested wording for "Storage and lifetime" or experiment 4: "Segment size is
chosen per pool from the churn experiment, which reports first-admission
charge, release frequency and live-record page offsets for each size tested."

Nothing else to correct. Product parameters and the hybrid recommendation
stand as written.
