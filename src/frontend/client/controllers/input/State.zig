const State = @This();
const source_namespace = @import("host_inputs.zig");
const Chunk = @import("Chunk.zig");
const deadline_timer = @import("telar-client").resources.deadline_timer;
const Config = @import("Config.zig");
const widgets = @import("../../../widgets/root.zig");
file: source_namespace.File,
router: source_namespace.Router,
/// The one in-flight TTY read lands here. The read task owns it until
/// its `.input` completion, and routing finishes before the next read is
/// armed, so the event carries a length instead of 4 KiB of bytes.
chunk: Chunk = .{},
read_pending: bool = false,
presentation_revision: u64 = 0,
input_timeout: deadline_timer.Scheduler = .{},
binding_timeout: deadline_timer.Scheduler = .{},
application_leases: source_namespace.key_routing.Leases = .{},
startup_input: @import("../../resources/startup_input.zig").State = .{},

/// Creates the host input state around the client-owned TTY handle.
///
/// ```zig
/// const state = try State.init(input_file, config);
/// ```
pub fn init(file: source_namespace.File, config: Config) !State {
    return .{ .file = file, .router = try source_namespace.buildRouter(config) };
}

/// Replaces the native router and wakes timers that still follow its old
/// partial input.
///
/// ```zig
/// state.replaceRouter(io, replacement);
/// ```
pub fn replaceRouter(state: *State, io: source_namespace.Io, replacement: source_namespace.Router) void {
    const prefix_was_pending = state.router.prefixPending();
    var inherited = replacement;
    inherited.inheritPhysicalLeases(&state.router);
    state.router = inherited;
    if (prefix_was_pending != state.router.prefixPending()) {
        state.presentation_revision +%= 1;
    }
    _ = state.input_timeout.update(io, null);
    _ = state.binding_timeout.update(io, null);
}

/// Returns the revision of visible host-input routing state.
///
/// ```zig
/// const revision = state.presentationVersion();
/// ```
pub fn presentationVersion(state: *const State) u64 {
    return state.presentation_revision;
}

/// Projects prefix help from the effective router without exposing its
/// matching state to the presenter.
///
/// ```zig
/// const mode = state.statusMode(copy_mode_active);
/// ```
pub fn statusMode(state: *const State, copy_mode_active: bool) widgets.status_bar.Mode {
    if (!state.router.prefixPending()) {
        return if (copy_mode_active) .copy else .normal;
    }

    const DescribedAction = struct {
        action: source_namespace.Action,
        label: []const u8,
    };
    const useful = [_]DescribedAction{
        .{ .action = .{ .split_pane = .horizontal }, .label = "split right" },
        .{ .action = .{ .split_pane = .vertical }, .label = "split down" },
        .{ .action = .new_tab, .label = "new tab" },
        .{ .action = .new_workspace, .label = "new workspace" },
        .{ .action = .rename_tab, .label = "rename tab" },
        .{ .action = .rename_workspace, .label = "rename workspace" },
        .{ .action = .close_pane, .label = "close pane" },
        .{ .action = .enter_copy_mode, .label = "copy mode" },
    };
    var hints: widgets.status_bar.Hints = .{};
    for (useful) |described| {
        const key = state.router.prefixedKeyForAction(described.action) orelse continue;

        hints.append(.{ .key = key, .label = described.label });
    }

    return .{ .prefix = hints };
}
