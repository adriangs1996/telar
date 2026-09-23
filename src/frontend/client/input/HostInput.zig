const client = @import("telar-client");
const data = @import("model");
const std = @import("std");
const host_inputs = @import("host_inputs.zig");
const Chunk = @import("Chunk.zig");
const StartupInput = @import("../session/StartupInput.zig");
const HostInput = @This();

file: std.Io.File,
router: host_inputs.Router,
/// The one in-flight TTY read lands here. The read task owns it until
/// its `.input` completion, and routing finishes before the next read is
/// armed, so the event carries a length instead of 4 KiB of bytes.
chunk: Chunk = .{},
read_pending: bool = false,
presentation_revision: u64 = 0,
input_timeout: client.Scheduler = .{},
binding_timeout: client.Scheduler = .{},
startup_input: StartupInput = .{},

/// Creates the host input state around the client-owned TTY handle.
///
/// ```zig
/// const state = try HostInput.init(input_file, config);
/// ```
pub fn init(file: std.Io.File, config: client.RouterConfig) !HostInput {
    return .{ .file = file, .router = try host_inputs.buildRouter(config) };
}

/// Replaces the native router and wakes timers that still follow its old
/// partial input.
///
/// ```zig
/// state.replaceRouter(io, replacement);
/// ```
pub fn replaceRouter(self: *HostInput, io: std.Io, replacement: host_inputs.Router) void {
    const prefix_was_pending = self.router.prefixPending();
    var inherited = replacement;
    inherited.inheritPhysicalLeases(&self.router);
    self.router = inherited;
    if (prefix_was_pending != self.router.prefixPending()) {
        self.presentation_revision +%= 1;
    }
    _ = self.input_timeout.update(io, null);
    _ = self.binding_timeout.update(io, null);
}

/// Returns the revision of visible host-input routing state.
///
/// ```zig
/// const revision = state.presentationVersion();
/// ```
pub fn presentationVersion(self: *const HostInput) u64 {
    return self.presentation_revision;
}

/// Projects prefix help from the effective router without exposing its
/// matching state to the presenter.
///
/// ```zig
/// const mode = state.statusMode(copy_mode_active);
/// ```
pub fn statusMode(self: *const HostInput, copy_mode_active: bool) client.Mode {
    if (!self.router.prefixPending()) {
        return if (copy_mode_active) .copy else .normal;
    }

    const DescribedAction = struct {
        action: data.Action,
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
    var hints: client.Hints = .{};
    for (useful) |described| {
        const key = self.router.prefixedKeyForAction(described.action) orelse continue;

        hints.append(.{ .key = key, .label = described.label });
    }

    return .{ .prefix = hints };
}
