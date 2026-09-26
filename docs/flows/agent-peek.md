# Agent peek

A right click on an agent or task card peeks at it without changing tab or
focus: a modal shows the task, its state and plan, and the last rows of its
pane, with a field whose text goes to the agent.

## End-to-end path

```text
right press on a card (GUI routing.secondaryIntent, TUI State.handleMouse)
        |
Intent.peek_agent -> agent_peek.open
        |  name_prompt: PromptTarget.peek
        |  PeekScreen.show
        |  read_pane{rows = 16} with continuation .peek_screen
        |
schema.pane_text -> runtime_messages -> agent_peek.receiveScreen -> PeekScreen.store
        |
every agent snapshot while open -> agent_peek.requestScreen (one read in flight)
        |
Enter -> agent_peek.submit
        |  empty or /open  -> agent_navigation.navigateAgent
        |  /stop           -> interrupt_agent
        |  /diff           -> launch_worktree: diff against the merge base, then a shell
        |  text            -> send_pane_text{mode = prompt}
Esc or submit -> agent_peek.settle -> PeekScreen.close
```

## Ownership

Everything here is client state: the prompt, the peeked agent and up to
4 KiB of its pane text. The actions are the same requests the coordinator
sends, so the focus rule, the blocked refusal and the interrupt key apply
unchanged; a refusal arrives as a request-failure notice. The GUI draws the
pane rows in `PeekModal`; the TUI shows the field only, since the sidebar
card already carries the state.

## Proof

Command parsing and pane-row selection tests.
