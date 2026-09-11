const key_routing = @import("key_routing.zig");
const PaneIdType = @import("telar-core").PaneId;
const KeyRoutingHandler = @import("KeyRoutingHandler.zig");
const KeyRoutingEffects = @import("KeyRoutingEffects.zig");
const KeyType = @import("../../input/Key.zig");
const PaneCommand = @import("PaneCommand.zig");
const Capture = @This();

events: [5]key_routing.Event = undefined,
event_count: usize = 0,
command: ?key_routing.Command = null,
pane_delivered: bool = true,
pane_id: PaneIdType = @enumFromInt(1),
pane_target: ?key_routing.PaneTarget = null,
failure: key_routing.Failure = .none,
leases: key_routing.Leases = .{},

pub fn routingHandler(capture: *Capture) KeyRoutingHandler {
    return .{
        .effects = capture.effects(),
        .leases = &capture.leases,
    };
}

fn effects(capture: *Capture) KeyRoutingEffects {
    return .{
        .context = capture,
        .close_modal = closeModal,
        .prompt = prompt,
        .copy_key = copyKey,
        .pane = pane,
        .preview = preview,
    };
}

fn record(capture: *Capture, event: key_routing.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn closeModal(raw_context: *anyopaque) void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.close_modal);
}

fn prompt(raw_context: *anyopaque, command: key_routing.Command) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.prompt);
    capture.command = command;

    if (capture.failure == .prompt) {
        return error.PromptInputFailed;
    }
}

fn copyKey(raw_context: *anyopaque, key: KeyType) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.copy_key);
    capture.command = .{ .key = key };

    if (capture.failure == .copy_key) {
        return error.CopyModeInputFailed;
    }
}

fn pane(raw_context: *anyopaque, command: PaneCommand) !?PaneIdType {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.pane);
    capture.command = command.input;
    capture.pane_target = command.target;

    if (capture.failure == .pane) {
        return error.PaneInputFailed;
    }

    if (!capture.pane_delivered) {
        return null;
    }

    return switch (command.target) {
        .current => capture.pane_id,
        .lease => |pane_id| pane_id,
    };
}

fn preview(raw_context: *anyopaque) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.preview);

    if (capture.failure == .preview) {
        return error.ClipboardPreviewFailed;
    }
}
