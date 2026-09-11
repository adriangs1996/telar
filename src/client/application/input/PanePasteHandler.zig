const PanePasteHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("PanePasteEffects.zig");
const source_namespace = @import("pane_paste.zig");
const std = @import("std");
model: *client_model.Model,
effects: Effects,

/// Captures one pane and rolls the session back when its opening marker
/// cannot enter the pane-input path.
///
/// ```zig
/// _ = try handler.start();
/// ```
pub fn start(handler: *PanePasteHandler) !source_namespace.Outcome {
    const session = handler.model.beginPanePaste() orelse return .ignored;
    errdefer {
        const rolled_back = handler.model.finishPanePaste(session);
        std.debug.assert(rolled_back);
    }

    if (!session.bracketed_paste) {
        return .applied;
    }

    if (!try handler.effects.deliver(handler.effects.context, .{ .marker = .{
        .session = session,
        .boundary = .start,
    } })) {
        const rolled_back = handler.model.finishPanePaste(session);
        std.debug.assert(rolled_back);
        return .unavailable;
    }

    return .applied;
}

/// Delivers one chunk to the exact session captured at paste start.
///
/// ```zig
/// _ = try handler.content(bytes);
/// ```
pub fn content(handler: *PanePasteHandler, text: []const u8) !source_namespace.Outcome {
    const session = handler.model.panePasteSession() orelse return .ignored;
    const delivered = try handler.effects.deliver(handler.effects.context, .{ .content = .{
        .session = session,
        .text = text,
    } });

    return if (delivered) .applied else .unavailable;
}

/// Clears the exact session even when its closing marker cannot be sent.
///
/// ```zig
/// _ = try handler.finish();
/// ```
pub fn finish(handler: *PanePasteHandler) !source_namespace.Outcome {
    const session = handler.model.panePasteSession() orelse return .ignored;
    defer {
        const finished = handler.model.finishPanePaste(session);
        std.debug.assert(finished);
    }

    if (!session.bracketed_paste) {
        return .applied;
    }

    const delivered = try handler.effects.deliver(handler.effects.context, .{ .marker = .{
        .session = session,
        .boundary = .finish,
    } });

    return if (delivered) .applied else .unavailable;
}
