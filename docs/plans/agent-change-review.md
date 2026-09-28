# Directed development and change review

Status: on hold. This design builds on managed agent panes, which telar
removed; the source links below point at deleted files. It needs a new base
before any implementation. No implementation has been started. Product decisions below come from the design interview; the proposed
runtime contracts still require the technical proofs listed below.

Terms are defined in [CONTEXT.md](../../CONTEXT.md#change-review). Implementation
must follow the [invariants](../invariants.md), including
[presentation delivery](../invariants.md#presentation-delivery).

## Purpose and scope

The user directs implementation through natural language while inspecting and
editing real code. One managed agent and the user take exclusive collaboration
turns. The UI provides a code editor alongside the conversation, with
navigation, search, selection, direct editing and syntax highlighting.
Neovim is an interaction reference; the editor engine remains an implementation
choice.

This is a new directed mode. The existing agent-pane behavior remains the
default and does not change. Arbitrary terminal agents, autonomous shared-tree
auditing, branching development history and resuming from older accepted steps
are outside this work. Archiving a session independently of a deleted worktree
is also outside the current scope.

## Entering a directed session

A session can be activated on an existing managed agent conversation and its
current code. Activation requires the agent to be stopped and the working tree
to be exclusive to that session. Subagents are not allowed in directed mode.

The initial code, including existing uncommitted modifications, becomes the
session baseline. Discarding later steps must preserve that prior work.
Activation must not silently replace the current working state with Git HEAD.

Review covers changes intended to remain in the project. Disposable utilities
and experiments have a designated separate area. Incorporating their contents
or resulting code into the project requires a proposal. A temporary script
does not exempt its modifications to project files from review.

## Turns and steps

A collaboration turn grants one participant control of the work. A review step
has an agreed change objective and may span multiple turns, including questions,
manual edits and implementation revisions. A provider model exchange is neither
of these concepts.

The user explicitly chooses Ask or Request change when sending a message.
Natural-language wording does not determine implementation authority.

- An explanation turn answers the question and returns control. It does not
  continue an earlier implementation task or make further project changes.
- An implementation turn works on one agreed objective, possibly across several
  files, then returns control. An overly broad request first produces a proposed
  breakdown and returns to the user before implementation.
- During the user's turn, the agent cannot modify the project. During the
  agent's turn, user editing and new instructions are disabled.
- Read-only inspection remains available during the agent's turn. Stop is an
  exceptional cancellation request, not an immediate transfer of edit authority.

Mechanical changes can be grouped into a reviewable step to avoid separate
interruptions. Any review exemptions require user-authorized categories; the
agent's own classification does not grant an exemption.

The agent may provide context explaining why it proposes a modification when
it considers that useful. A rationale is not mandatory for every step. The
user can request more context in an explanation turn.

## Drafts and review actions

A step draft exists in the private working tree before acceptance, so the code
being reviewed can be edited and executed. Human edits are saved and synchronized
before handing control to the agent. If synchronization fails, the agent's turn
does not start.

Acceptance means the user is satisfied to advance from the current state.
It does not certify that the whole feature is finished or that tests pass.
A question, manual edit or turn handoff never implicitly accepts a step.

| Action | Effect |
| --- | --- |
| Ask | Synchronize the current code, grant an explanation turn, then return control. |
| Request change | Grant one implementation turn for an agreed objective. A revision of the current step starts from its current draft. |
| Accept | Record explicit acceptance of the current revision without starting additional work. |
| Accept and continue | Accept the current revision and grant only the next agreed step. If there is no agreed next objective, obtain a proposal before further implementation. |
| Discard and redo | Retain the rejected draft and user feedback, restore the state preceding the current step, and grant one replacement implementation turn under the revised instructions. |
| Discard and abandon | Retain the rejected attempt and restore the state preceding the current step without requesting further work. |
| Stop | Request cancellation and wait until the agent can no longer make project changes before restoring user edit authority. |

Discard reverses both human and agent contributions made during the current
step. Requesting a revision instead preserves that draft. A redo includes the
rejection and new direction in the agent's assignment; restoring files alone
does not revise the assignment.

The precise button labels and layout remain UI choices. The action semantics
above do not depend on a particular editor or provider.

## Linear session history

Telar has its own notion of review history. Its storage backend is an
implementation detail. Accepting a step does not require an ordinary Git commit
or an automatic change to the user's branch or staging area.

History retains each code version delivered for review and associates its
conversation with that version. Versions that are later revised or rejected
remain available for inspection. The main view emphasizes accepted results and
can expand earlier attempts. Internal edits made before a delivery are not
individual review revisions.

The history stays linear. Discarding the current step and retrying records
subsequent events in the same session; it does not create a development branch.
Older accepted steps can be inspected and compared, but resuming development
from them is outside this scope.

Long-term retention after worktree deletion is not a requirement. This does
not remove the agreed need to reconnect to an active session or recover an
interrupted one. Storage must distinguish active-session recovery from an
optional future archive.

## Disconnection and interruption

Closing the UI during an agent turn lets only that authorized turn finish.
The session then waits for review. Reopening restores the pending draft and
conversation. A UI disconnection neither accepts a step nor authorizes another.

If the runtime fails during work, recovery presents the attempt as interrupted
with the recoverable state available. It does not automatically resume project
mutations. This is not a promise of process continuity after runtime death.

Stop must not unlock editing merely because a cancellation request was sent.
Likewise, a provider's ready or completed status alone is not proof that all
processes capable of modifying the project have stopped.

## Proposed runtime contracts

These are engineering consequences of the product contract, not yet implemented
mechanisms or verified provider guarantees.

| Owner | Responsibility |
| --- | --- |
| Runtime | Directed-session identity, baseline, active step, turn authority, acceptance, rejection feedback, review revisions and recovery status. |
| Client | Editor and conversation presentation, selection, navigation, focus and user requests. UI availability reflects runtime authority. |
| Provider adapter | Execute the authorized turn, deliver its events and establish the capabilities required to restrict writing, subagents and cancellation. |
| Editor integration | Expose versioned contents, enforce edit ownership, and synchronize the code used for the next agent turn. |
| Bounded workers | Code capture, comparison, persistence and provider I/O outside the terminal input and rendering paths. |

A collaboration handoff must establish three facts before granting authority:
the previous writer can no longer modify the project, the current code is
synchronized, and the review state needed for that handoff is retained.
Sending a UI notification or rejecting a stale RPC response cannot by itself
stop a process that still has filesystem write access.

Turn identity and code revision must accompany state-changing requests so stale
clients or old provider completions cannot act on a later turn. Acceptance
refers to the current review revision, not whichever historical document the
user happens to be inspecting.

Code capture and storage failures must be explicit. A failed handoff cannot be
reported as completed, and a failed acceptance cannot start the next step.
Workers may delay a directed-session transition without blocking the runtime
event loop, terminal input or other panes.

The agreed objective sets the scope of an implementation turn. Whether an edit
actually satisfies that objective remains subject to agent reporting and human
review; a filesystem permission boundary cannot establish semantic correctness.

## Existing implementation evidence

Static inspection identifies reusable pieces and limits. The tests referenced
during the investigation were read, not executed for this design.

- [Session.submit](../../src/backend/agent_panes/Session.zig) serializes prompts
  and rejects submissions outside the provider's ready state. It does not
  represent review steps or control an editor's write authority.
- [Codex](../../src/backend/agent_panes/Codex.zig) can request a read-only sandbox
  for a turn, but [AgentSubmission](../../src/core/AgentSubmission.zig) does not
  distinguish explanation from implementation intent. Provider permissions alone
  do not implement the complete directed-session contract.
- Provider turn completion currently returns the session to ready. Interrupt
  requests cancellation without a separate check that all project writers have
  stopped. Ready cannot be reused as the directed editor's write permission.
- [ChildAgents](../../src/backend/agent_panes/ChildAgents.zig) observes subagents;
  it does not prevent their creation.
- [PaneRecord](../../src/backend/persistence/PaneRecord.zig) and the agent session
  checkpoint preserve a thread reference and name, not review-step state,
  revisions, a code-editor draft or collaboration-turn ownership.
- The [Neovim integration](../../integrations/nvim/README.md) handles navigation
  between editor windows and Telar panes. Shared versioned contents and turn
  ownership are new contracts.

## Technical proof before implementation is committed

The storage backend and editor engine should be selected against these contracts.
In particular, demonstrate the following with the initial provider and editor
before building the full directed-mode UI:

1. An explanation turn cannot modify project code, including through a shell
   command or an approval path that would otherwise grant broader permissions.
2. Directed operation prevents subagents and accounts for subprocesses that can
   outlive an ordinary provider turn. Cancellation has a real completion barrier
   before user editing is enabled.
3. A human handoff gives the agent exactly the synchronized editor version.
   Failed saves, stale commands and external file changes cannot silently replace
   the version under review.
4. Activation preserves initial uncommitted code. Discard and redo restore the
   current step's starting state and send rejection feedback to the next attempt.
5. Accepted and rejected review revisions remain tied to the conversation about
   them, while the history stays linear and ordinary Git state is not modified
   merely by accepting a step.
6. A broad request requires an agreed step; accepting and continuing never grants
   the rest of the plan implicitly.
7. Closing and reopening the UI preserves the pending review. Runtime recovery
   marks interrupted work and does not silently issue another implementation turn.
8. Slow or failed code capture, persistence and editor/provider workers leave
   other panes and terminal input responsive.

Before implementation, specify bounds for document size, retained revisions,
conversation text, worker queues, storage, operation deadlines and subprocesses.
Apply the existing history redaction, private-storage and recovery invariants
to the selected implementation.

The proposed engineering defaults for the remaining failure cases are:

- Retain human edits acknowledged by the session's editor service across UI
  disconnection. Saving those contents for execution is a separate operation at
  handoff. Runtime-crash recovery must state its durable save boundary; it must
  not claim to recover input that was never acknowledged or persisted.
- If project files change outside the directed session, invalidate the expected
  code version and pause the affected transition. Do not overwrite that work
  during discard or continue from an undisclosed stale base. Reconcile the
  current contents before granting another implementation turn.
- Associate validation output with the code revision and time at which it was
  obtained. Later edits do not inherit a passing result for an earlier revision.
  Validation status remains separate from human acceptance.

These policies must be checked against the chosen editor and provider. They do
not expand the scope to autonomous auditing, branching history or long-term
archival.
