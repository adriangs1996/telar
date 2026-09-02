//! Application policy binding local previews to one agent prompt's image markers.

const std = @import("std");
const core = @import("telar-core");
const attachments = @import("../../../attachments/root.zig");
const client_model = @import("../../model/root.zig");
const key_routing = @import("key_routing.zig");

const schema = core.schema;

pub const RemovalCommand = struct {
    pane_id: schema.PaneId,
    marker: attachments.MarkerRemoval,
};

pub const DismissEffects = struct {
    context: *anyopaque,
    plan: *const fn (*anyopaque, attachments.Id) ?RemovalCommand,
    deliver: *const fn (*anyopaque, RemovalCommand) anyerror!void,
    remove: *const fn (*anyopaque, attachments.Id) ?bool,
};

pub const DismissAttachmentHandler = struct {
    effects: DismissEffects,

    /// Deletes the child marker before retiring its paired local preview.
    ///
    /// ```zig
    /// const layout_changed = try handler.execute(id);
    /// ```
    pub fn execute(handler: *DismissAttachmentHandler, id: attachments.Id) !bool {
        const command = handler.effects.plan(handler.effects.context, id) orelse return false;
        try handler.effects.deliver(handler.effects.context, command);

        return handler.effects.remove(handler.effects.context, id) orelse false;
    }
};

pub const ObserveEffects = struct {
    context: *anyopaque,
    visible_target: *const fn (*anyopaque) ?attachments.Target,
    marker_at_cursor: *const fn (*anyopaque, attachments.MarkerDeletion) ?attachments.Id,
    pending_marker_at_cursor: *const fn (*anyopaque, attachments.MarkerDeletion) bool,
    remove: *const fn (*anyopaque, attachments.Id) ?bool,
    remove_prompt: *const fn (*anyopaque, attachments.Target) ?bool,
};

pub const ObservePaneInputHandler = struct {
    model: *client_model.Model,
    effects: ObserveEffects,

    /// Mirrors marker deletion and prompt submission only after the child
    /// input was accepted by the pane-input boundary.
    ///
    /// ```zig
    /// const layout_changed = handler.execute(pane_id, command);
    /// ```
    pub fn execute(handler: *ObservePaneInputHandler, pane_id: schema.PaneId, command: key_routing.Command) bool {
        const key = switch (command) {
            .bytes => return false,
            .key => |value| value,
        };
        if (key.phase == .release or key.mods.ctrl or key.mods.alt or key.mods.shift) {
            return false;
        }

        const target = handler.effects.visible_target(handler.effects.context) orelse
            handler.model.focusedAttachmentTarget() orelse return false;
        if (target.pane_id != pane_id) {
            return false;
        }

        switch (key.code) {
            .enter => {
                _ = handler.model.cancelClipboardCapture(target);

                return handler.effects.remove_prompt(handler.effects.context, target) orelse false;
            },
            .backspace, .delete => {
                const deletion: attachments.MarkerDeletion = if (key.code == .backspace) .backward else .forward;
                const id = handler.effects.marker_at_cursor(handler.effects.context, deletion);
                if (id == null) {
                    if (handler.effects.pending_marker_at_cursor(handler.effects.context, deletion)) {
                        _ = handler.model.cancelClipboardCapture(target);
                    }

                    return false;
                }

                return handler.effects.remove(handler.effects.context, id.?) orelse false;
            },
            else => return false,
        }
    }
};

const Event = enum {
    plan,
    deliver,
    remove,
};

const DismissCapture = struct {
    events: [3]Event = undefined,
    count: usize = 0,
    layout_changed: bool = false,
    plan_available: bool = true,

    fn effects(capture: *DismissCapture) DismissEffects {
        return .{ .context = capture, .plan = plan, .deliver = deliver, .remove = remove };
    }

    fn append(capture: *DismissCapture, event: Event) void {
        capture.events[capture.count] = event;
        capture.count += 1;
    }

    fn plan(raw_context: *anyopaque, _: attachments.Id) ?RemovalCommand {
        const capture: *DismissCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.plan);
        if (!capture.plan_available) {
            return null;
        }

        return .{
            .pane_id = @enumFromInt(7),
            .marker = .{ .direction = .left, .steps = 1, .deletion = .backward },
        };
    }

    fn deliver(raw_context: *anyopaque, _: RemovalCommand) !void {
        const capture: *DismissCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.deliver);
    }

    fn remove(raw_context: *anyopaque, _: attachments.Id) ?bool {
        const capture: *DismissCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.remove);

        return capture.layout_changed;
    }
};

test "preview dismissal deletes the child marker before retiring local media" {
    var capture: DismissCapture = .{ .layout_changed = true };
    var handler: DismissAttachmentHandler = .{ .effects = capture.effects() };

    try std.testing.expect(try handler.execute(@enumFromInt(3)));
    try std.testing.expectEqualSlices(Event, &.{ .plan, .deliver, .remove }, capture.events[0..capture.count]);

    capture = .{ .plan_available = false };
    handler = .{ .effects = capture.effects() };
    try std.testing.expect(!try handler.execute(@enumFromInt(3)));
    try std.testing.expectEqualSlices(Event, &.{.plan}, capture.events[0..capture.count]);
}

const ObserveCapture = struct {
    target: attachments.Target,
    marker: ?attachments.Id = null,
    pending_marker: bool = false,
    removed: ?attachments.Id = null,
    prompt_removed: bool = false,

    fn effects(capture: *ObserveCapture) ObserveEffects {
        return .{
            .context = capture,
            .visible_target = visibleTarget,
            .marker_at_cursor = markerAtCursor,
            .pending_marker_at_cursor = pendingMarkerAtCursor,
            .remove = remove,
            .remove_prompt = removePrompt,
        };
    }

    fn visibleTarget(raw_context: *anyopaque) ?attachments.Target {
        const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));

        return capture.target;
    }

    fn markerAtCursor(raw_context: *anyopaque, _: attachments.MarkerDeletion) ?attachments.Id {
        const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));

        return capture.marker;
    }

    fn pendingMarkerAtCursor(raw_context: *anyopaque, _: attachments.MarkerDeletion) bool {
        const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));

        return capture.pending_marker;
    }

    fn remove(raw_context: *anyopaque, id: attachments.Id) ?bool {
        const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));
        capture.removed = id;

        return false;
    }

    fn removePrompt(raw_context: *anyopaque, target: attachments.Target) ?bool {
        const capture: *ObserveCapture = @ptrCast(@alignCast(raw_context));
        std.debug.assert(std.meta.eql(capture.target, target));
        capture.prompt_removed = true;

        return true;
    }
};

test "pane input mirrors marker deletion and submission into preview state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const target: attachments.Target = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 };
    var capture: ObserveCapture = .{ .target = target, .marker = @enumFromInt(3) };
    var handler: ObservePaneInputHandler = .{ .model = &model, .effects = capture.effects() };

    try std.testing.expect(!handler.execute(target.pane_id, .{ .key = .{ .code = .backspace } }));
    try std.testing.expectEqual(@as(attachments.Id, @enumFromInt(3)), capture.removed.?);

    _ = try model.beginClipboardCapture(target);
    try std.testing.expect(handler.execute(target.pane_id, .{ .key = .{ .code = .enter } }));
    try std.testing.expect(capture.prompt_removed);
    try std.testing.expect(model.clipboardCapture() == null);

    _ = try model.beginClipboardCapture(target);
    capture.marker = null;
    capture.pending_marker = true;
    try std.testing.expect(!handler.execute(target.pane_id, .{ .key = .{ .code = .delete } }));
    try std.testing.expect(model.clipboardCapture() == null);
}
