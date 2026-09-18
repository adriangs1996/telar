# Agent change review

Status: design interview in progress. This records agreed product constraints
and unresolved questions, not an implementation plan or existing capabilities.
Terms are defined in [CONTEXT.md](../../CONTEXT.md#change-review).

## Intended experience

The user wants to direct implementation without having to write all the code.
In a directed session, natural-language instructions become agent actions
visible in an interactive code editor. During their turn, the user can navigate
the code, ask for context, suggest revisions, and edit it manually. Questions
and answers remain visible in a conversation alongside the editor. Accepting
or rejecting diffs alone does not describe this experience.

The original autonomous mode remains in scope: agents work independently and
the user reviews the evolution afterward. Its shared-working-tree concurrency
and evidence guarantees remain unresolved. Constraints agreed for directed
sessions do not automatically apply to autonomous sessions.

## Agreed constraints

- Directed sessions use managed agent panes. Supporting future providers
  requires the control capabilities needed by the mode; arbitrary agents
  launched in terminal panes are outside this contract.
- One agent works synchronously with the user, without subagents, in a working
  tree that other agents do not share. Pending changes are not exposed to other
  agents.
- Review concerns changes intended to remain in the project. Disposable
  utilities and experiments have an explicit separate area. Incorporating
  their files or resulting code changes into the project requires a proposal.
  A temporary script that modifies project code does not exempt those changes.
- Mechanical changes may be grouped into a reviewable step to avoid separate
  interruptions. Review exemptions require explicit user-authorized categories;
  the agent's classification alone does not authorize skipping review.
- Direct human editing is part of the intended experience, alongside
  natural-language direction and contextual questions.
- Collaboration is cooperative and turn-based. During normal operation, the
  user waits for the agent to yield, and the agent waits until the user hands
  control back. The user cannot edit during the agent's turn, and the agent
  cannot modify the project during the user's turn.
- A request for context gives the agent a turn to answer that question, without
  implementing further changes. It does not resume an earlier implementation
  task automatically.
- The user explicitly chooses between asking a question and requesting a
  change when sending a message. Free-form wording does not decide the turn's
  implementation authority.
- Each implementation turn has an agreed objective and ends when that objective
  is complete. It may involve several files. An overly broad request first
  produces a proposed breakdown and returns control to the user.
- A review step may span questions, answers, manual edits and implementation
  revisions. Accepting the step is an explicit user action, such as "Accept
  and continue"; handing control back does not accept it implicitly.
- Read-only inspection remains available during the agent's turn. Editing and
  sending new instructions wait for the user's turn. Exceptional cancellation
  requests a stop and returns control only after the agent can no longer make
  project changes; clicking Stop does not immediately unlock editing while an
  operation is still running.
- The UI includes both a code editor and the user-agent conversation. Code
  navigation, search, selection, direct editing and syntax highlighting are
  required. The editor engine remains an implementation choice; Neovim itself
  is not a requirement.

## Open decisions

- Whether proposed code is applied to the session's private working tree before
  review, and what separates a mutable draft from accepted project changes.
- How manual edits and unsaved buffers become the agent's next working base,
  and what happens to pending actions prepared against an earlier version.
- How a step is revised, discarded or partially accepted, including manual
  edits made during that step and partially completed work after cancellation.
- What validation is required before accepting a step and how later edits
  affect previously observed validation results.
- Whether accepting a step also starts an already agreed next step, or returns
  the session to planning; which authority the Continue action grants.
- What events, drafts, decisions and content versions are retained, with what
  attribution, durability and coverage guarantees in each mode.
- Whether autonomous agents must support concurrent writes to the same working
  tree, and how that history remains reviewable.

## Implementation choices not made

No choice has been made between Git commits, another version store, editor
integration, provider hooks, or mediated filesystem operations. Existing
provider approval settings are not the directed-session interaction contract.
