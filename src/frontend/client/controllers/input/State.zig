const std = @import("std");
const host_inputs = @import("host_inputs.zig");
const Chunk = @import("Chunk.zig");
const SchedulerType = @import("telar-client").Scheduler;
const StartupInputState = @import("../../resources/StartupInputState.zig");
const Config = @import("telar-client").RouterConfig;
const ModeType = @import("telar-client").Mode;
const ActionType = @import("telar-client").Action;
const HintsType = @import("telar-client").Hints;
const State = @This();

file: std.Io.File,
router: host_inputs.Router,
/// The one in-flight TTY read lands here. The read task owns it until
/// its `.input` completion, and routing finishes before the next read is
/// armed, so the event carries a length instead of 4 KiB of bytes.
chunk: Chunk = .{},
read_pending: bool = false,
presentation_revision: u64 = 0,
input_timeout: SchedulerType = .{},
binding_timeout: SchedulerType = .{},
startup_input: StartupInputState = .{},

/// Creates the host input state around the client-owned TTY handle.
///
/// ```zig
/// const state = try State.init(input_file, config);
/// ```
pub fn init(file: std.Io.File, config: Config) !State {
    return .{ .file = file, .router = try host_inputs.buildRouter(config) };
}

/// Replaces the native router and wakes timers that still follow its old
/// partial input.
///
/// ```zig
/// state.replaceRouter(io, replacement);
/// ```
pub fn replaceRouter(state: *State, io: std.Io, replacement: host_inputs.Router) void {
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
pub fn statusMode(state: *const State, copy_mode_active: bool) ModeType {
    if (!state.router.prefixPending()) {
        return if (copy_mode_active) .copy else .normal;
    }

    const DescribedAction = struct {
        action: ActionType,
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
    var hints: HintsType = .{};
    for (useful) |described| {
        const key = state.router.prefixedKeyForAction(described.action) orelse continue;

        hints.append(.{ .key = key, .label = described.label });
    }

    return .{ .prefix = hints };
}
