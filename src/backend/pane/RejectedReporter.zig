/// A process a recheck found reporting for another agent than the pane's,
/// keyed to the pane's agent: its hooks are refused at once while that
/// agent, as the probe identified it, runs the pane.
const RejectedReporter = @This();

/// The pane agent's process group and its own process.
group: u32,
agent: u32,
/// The reporting process, never the pane's agent.
process: u32,
