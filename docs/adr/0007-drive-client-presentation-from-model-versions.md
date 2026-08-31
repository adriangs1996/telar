---
status: accepted
---

# Drive client presentation from model versions

Client application handlers currently mutate disposable state and often request
a draw in the same operation. That couples a use case to presentation policy
and makes it unclear whether a repeated or rejected mutation should produce a
frame.

## Decision

The disposable client keeps semantic state in a passive `ClientModel`.
Application handlers commit that state without deciding whether or when to
draw. A committed semantic change advances a bounded model version; a rejected
operation or canonical no-op does not.

After each client event, the client loop gives `Presenter` the current model
version and the observable revisions of presentation-owned resource stores,
view interactions and visible input routing.
The presenter stores observed and presented revisions, coalesces changes onto
its existing paced deadline, selects damaged presentation regions and caps
cell presentation at 60 Hz. An unchanged idle client schedules no frame.
Time-driven presentation work schedules its own ticks.

Operational state such as requests, delivery and workers does not belong to
the model. Presentation state such as screen buffers, pacing, damage caches and
host graphics also remains outside it. A physical store may expose a monotonic
revision for presentation without moving its resources into `ClientModel`.
The same rule applies to disposable hover, sidebar scroll, attachment-modal and
prefix-router state. Their owners expose revisions through
`PresentationIngress`; input handlers do not return redraw commands.
The target presentation boundary reads an immutable projection of
`ClientModel`; rendering does not perform semantic mutations.

`presentation_projection` is the only adapter that translates the concrete
`Client` aggregate into that bounded immutable input and the mutable resources
owned by presentation. `Presenter` neither imports nor receives `Client`.
Scheduling is an opaque port supplied by the composition root, so pacing does
not depend on the client event-union representation.

Pane composition caches belong to `multiplexer.Compositor`, which is owned by
`Presenter`. The workspace model contains semantic pane cells, damage and
layout, but no last-painted buffer, copy projection or invalidation flag. The
compositor detects changes between immutable projections and returns a bounded
`PresentationCommit`. Only after the host cell flush succeeds does
`presentation_lifecycle` apply that commit to retire the exact pane damage and
frame identifiers that reached the host. A stale commit cannot retire a newer
frame.

`moveTab` is the first vertical slice. The action records a continuation and
emits the runtime request without reordering locally. The canonical runtime
reply commits the position through `ClientModel`; the handler does not request
a draw. The presenter observes the resulting version at the client-loop
boundary.

## Considered options

- Returning draw effects from each application handler would couple use cases to presentation policy.
- Polling the model continuously at 60 Hz would wake an unchanged client and waste CPU.

## Consequences

`Presenter` stores version values rather than copying the model and emits
nothing when the resulting screen matches the host projection. Application
tests can distinguish command delivery, semantic commit and presentation as
three separate boundaries.

The immutable projection borrows bounded model snapshots only for the duration
of one synchronous presentation call. It adds no allocation or queue to the
interactive path. Copy-mode selection deltas update only affected cell ranges;
model damage remains reserved for runtime frame changes.
