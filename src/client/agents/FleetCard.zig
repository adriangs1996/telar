/// How the sidebar draws one agent of the fleet.
pub const FleetCard = enum {
    /// An agent in its project's own checkout: the ordinary agent card.
    agent,
    /// A task that needs the person, or the selected one: three rows.
    task_full,
    /// A task that progresses on its own: one line.
    task_compact,
};
