//! Where an open panel's components come from: a render callback, or a
//! command whose output a render may read. A panel never holds static
//! components, so its definition stays the size of one command.
const Command = @import("BarCommand.zig");
const Dynamic = @import("Dynamic.zig");

pub const PanelSource = union(enum) {
    empty,
    dynamic: Dynamic,
    command: Command,

    /// How often the source runs while the panel is open; null when it
    /// runs once per opening.
    /// Example: `if (source.interval() != null) state.startPanel(run, now_ns);`
    pub fn interval(self: *const PanelSource) ?u64 {
        return switch (self.*) {
            .dynamic => |value| value.interval_ns,
            .command => |value| value.interval_ns,
            .empty => null,
        };
    }
};
