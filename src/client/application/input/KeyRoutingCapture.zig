const Capture = @This();
const source_namespace = @import("key_routing.zig");
const KeyRoutingHandler = @import("KeyRoutingHandler.zig");
const Effects = @import("KeyRoutingEffects.zig");
const PaneCommand = @import("PaneCommand.zig");
events: [5]source_namespace.Event = undefined,
event_count: usize = 0,
command: ?source_namespace.Command = null,
pane_delivered: bool = true,
pane_id: source_namespace.schema.PaneId = @enumFromInt(1),
pane_target: ?source_namespace.PaneTarget = null,
failure: source_namespace.Failure = .none,
leases: source_namespace.Leases = .{},

pub fn routingHandler(capture: *Capture) KeyRoutingHandler {
    return .{
        .effects = capture.effects(),
        .leases = &capture.leases,
    };
}

fn effects(capture: *Capture) Effects {
    return .{
        .context = capture,
        .close_modal = closeModal,
        .prompt = prompt,
        .copy_key = copyKey,
        .pane = pane,
        .preview = preview,
    };
}

fn record(capture: *Capture, event: source_namespace.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn closeModal(raw_context: *anyopaque) void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.close_modal);
}

fn prompt(raw_context: *anyopaque, command: source_namespace.Command) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.prompt);
    capture.command = command;

    if (capture.failure == .prompt) {
        return error.PromptInputFailed;
    }
}

fn copyKey(raw_context: *anyopaque, key: source_namespace.keybind.Key) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.copy_key);
    capture.command = .{ .key = key };

    if (capture.failure == .copy_key) {
        return error.CopyModeInputFailed;
    }
}

fn pane(raw_context: *anyopaque, command: PaneCommand) !?source_namespace.schema.PaneId {
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
