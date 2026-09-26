# Agent status

The runtime decides what an agent is doing from independent evidence and
publishes one status per pane generation. `src/backend/runtime/agent_status.zig`
implements this flow over `RuntimeModel`.

## End-to-end path

```text
pane_observation (foreground process)  -> agent_status.observeProcess
pane_observation (screen)               -> agent_status.observeScreen
agent_hooks (lifecycle report)          -> agent_status.observeReport
  -> ensure: the pane generation's row in model.agents, created from
     identity evidence and seeded from model.restored_agents
  -> Agent.apply* on that row
  -> reproject: the row chooses its evidence and projects a status
  -> model.agent_revision advances when the projection changed
agent_maintenance.tick -> agent_status.expire (stale evidence, empty rows)
agent_snapshot.project -> agent_status.snapshot(&model.agents, ...)
```

## State

- `model.agents`: the `Agents` table, one `Agent` row per pane generation
  with evidence, indexed by pane id.
- `model.restored_agents`: titles and resumes from a checkpoint, held until
  their agent is observed.
- `model.agent_watches`: session files probed for names an agent gives its
  session.
- `model.agent_revision`, `model.agent_session_revision`,
  `model.agent_sequence`: what the snapshot and change review compare.

## Rules

- Screen text refines a status but never creates an agent; process or
  lifecycle evidence does.
- A lifecycle report outranks screen evidence until it expires: ten minutes
  for `working`, two for `settling`, thirty for settled states.
- A `continuing` report renews an unexpired `working` report and changes
  nothing else; it never creates an agent.
- A pending resume is dropped when the observed process belongs to another
  provider or the agent reports a different session.

## Tests

- `src/backend/runtime/tests/agent_status_test.zig`: registration,
  settlement, blocking, completion, titles, sessions and resumes.
- `src/backend/agent/Agent.zig`: evidence choice and projection of one row.
