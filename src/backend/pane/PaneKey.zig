const core = @import("telar-core");
/// Stable identity for work that can finish after the pane lifecycle moved
/// on. Generation makes future id reuse safe without changing actor events.
id: core.PaneId,
generation: u64,
