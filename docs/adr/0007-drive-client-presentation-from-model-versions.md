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
version and the observable revisions of presentation-owned resource stores.
The presenter stores observed and presented revisions, coalesces changes onto
its existing paced deadline, selects damaged presentation regions and caps
cell presentation at 60 Hz. An unchanged idle client schedules no frame.
Time-driven presentation work schedules its own ticks.

Operational state such as requests, delivery and workers does not belong to
the model. Presentation state such as screen buffers, pacing, damage caches and
host graphics also remains outside it. A physical store may expose a monotonic
revision for presentation without moving its resources into `ClientModel`.
The target presentation boundary reads an immutable projection of
`ClientModel`; rendering does not perform semantic mutations.

`moveTab` is the first vertical slice. The action records a continuation and
emits the runtime request without reordering locally. The canonical runtime
reply commits the position through `ClientModel`; the handler does not request
a draw. The presenter observes the resulting version at the client-loop
boundary.

Existing direct draw requests and direct workspace borrows may remain only for
flows not yet migrated. The current workspace model still contains composition
bookkeeping used by the legacy renderer, so embedding it in `ClientModel` is a
transitional ownership step, not the final immutable projection boundary.

## Considered options

- Returning draw effects from each application handler would couple use cases to presentation policy.
- Polling the model continuously at 60 Hz would wake an unchanged client and waste CPU.

## Consequences

`Presenter` stores version values rather than copying the model and emits
nothing when the resulting screen matches the host projection. Application
tests can distinguish command delivery, semantic commit and presentation as
three separate boundaries.

The first slice establishes the version signal and removes presentation policy
from `moveTab`. It does not remove legacy draw requests or finish extracting
composition state from the workspace projection; later slices must migrate
those responsibilities explicitly.
