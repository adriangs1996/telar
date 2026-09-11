const PaneInputHandler = @This();
const client_model = @import("../../root.zig").model;
const PaneInputEffects = @import("PaneInputEffects.zig");
const Command = @import("PaneInputCommand.zig");
const Delivery = @import("Delivery.zig");
const source_namespace = @import("pane_input.zig");
const PasteMarkerCommand = @import("PasteMarkerCommand.zig");
const set_pane_viewport = @import("../panes/root.zig").set_pane_viewport;
model: *client_model.Model,
effects: PaneInputEffects,

/// Encodes semantic keys before any commit, restores live output for key
/// presses, repeats and paste, then delivers bytes to the resolved pane.
/// Releases and mouse reports preserve the user's current viewport.
///
/// ```zig
/// const delivery = try handler.execute(command) orelse return;
/// ```
pub fn execute(handler: *PaneInputHandler, command: Command) !?Delivery {
    const plan = handler.model.planPaneInput(command.target) orelse return null;
    var encoded: [32]u8 = undefined;
    const prepared: Prepared = switch (command.payload) {
        .bytes => |value| .{ .source = command.source, .bytes = value },
        .key => |value| .{
            .source = command.source,
            .bytes = try source_namespace.host_input.encodeKey(&encoded, value, plan.input_modes),
            .restore_viewport = value.phase != .release,
            .empty_is_noop = true,
        },
    };
    if (prepared.bytes.len == 0 and prepared.empty_is_noop) {
        return null;
    }

    return try handler.deliver(plan, prepared);
}

/// Encodes one bounded synthetic key sequence as a single pane-input
/// transaction. This keeps cursor motion plus marker deletion atomic with
/// respect to Telar's outbox.
///
/// ```zig
/// _ = try handler.executeKeys(.{ .pane = pane_id }, keys);
/// ```
pub fn executeKeys(handler: *PaneInputHandler, target: client_model.PaneInputTarget, keys: []const source_namespace.keybind.Key) !?Delivery {
    if (keys.len == 0 or keys.len > source_namespace.max_keys) {
        return error.InvalidInputLength;
    }

    const plan = handler.model.planPaneInput(target) orelse return null;
    var encoded: [source_namespace.max_bytes]u8 = undefined;
    var len: usize = 0;
    for (keys) |key| {
        var key_bytes: [32]u8 = undefined;
        const bytes = try source_namespace.host_input.encodeKey(&key_bytes, key, plan.input_modes);
        if (bytes.len > encoded.len - len) {
            return error.InvalidInputLength;
        }

        @memcpy(encoded[len..][0..bytes.len], bytes);
        len += bytes.len;
    }

    return try handler.deliver(plan, .{ .source = .host, .bytes = encoded[0..len] });
}

/// Frames one bounded paste against the target child's current mode and
/// delivers it through the same viewport policy as streamed paste.
///
/// ```zig
/// const delivery = try handler.executePaste(.focused, "text");
/// ```
pub fn executePaste(handler: *PaneInputHandler, target: client_model.PaneInputTarget, text: []const u8) !?Delivery {
    const plan = handler.model.planPaneInput(target) orelse return null;
    const framing_bytes: usize = if (plan.input_modes.bracketed_paste) 12 else 0;
    if (text.len > source_namespace.max_bytes - framing_bytes) {
        return error.InvalidInputLength;
    }

    var encoded: [source_namespace.max_bytes]u8 = undefined;
    const bytes = try source_namespace.host_input.encodePaste(&encoded, text, plan.input_modes);

    return try handler.deliver(plan, .{
        .source = .paste,
        .bytes = bytes,
    });
}

pub const HistoryPaste = struct {
    target: client_model.PaneInputTarget,
    text: []const u8,
    run: bool,
};

/// Frames a complete history command and puts execution after the paste boundary.
/// The send port must atomically reserve the resulting bounded input batch.
/// Example: `_ = try handler.executeHistoryPaste(.{ .target = .focused, .text = command, .run = false });`.
pub fn executeHistoryPaste(handler: *PaneInputHandler, request: HistoryPaste) !?Delivery {
    const plan = handler.model.planPaneInput(request.target) orelse return null;
    try source_namespace.validateHistoryText(request.text, plan.input_modes.bracketed_paste);
    var encoded: [source_namespace.schema.max_history_command_bytes + 13]u8 = undefined;
    const paste = try source_namespace.host_input.encodePaste(&encoded, request.text, plan.input_modes);
    var len = paste.len;
    if (request.run) {
        encoded[len] = '\r';
        len += 1;
    }

    return try handler.deliver(plan, .{ .source = .paste, .bytes = encoded[0..len], .limit = encoded.len });
}

/// Delivers one explicit streamed-paste marker to an already captured
/// session. Framing policy belongs to the pane-paste use case.
///
/// ```zig
/// _ = try handler.executePasteMarker(command) orelse return;
/// ```
pub fn executePasteMarker(handler: *PaneInputHandler, command: PasteMarkerCommand) !?Delivery {
    const plan = handler.model.planPaneInput(command.target) orelse return null;

    const bytes = switch (command.marker) {
        .start => "\x1b[200~",
        .finish => "\x1b[201~",
    };

    return try handler.deliver(plan, .{
        .source = .paste,
        .bytes = bytes,
    });
}

const Prepared = struct {
    source: source_namespace.Source,
    bytes: []const u8,
    restore_viewport: bool = true,
    limit: usize = source_namespace.max_bytes,
    empty_is_noop: bool = false,
};

fn deliver(handler: *PaneInputHandler, plan: client_model.PaneInputPlan, prepared: Prepared) !Delivery {
    if (prepared.bytes.len == 0 or prepared.bytes.len > prepared.limit) {
        return error.InvalidInputLength;
    }

    if (prepared.source != .mouse) {
        _ = handler.model.clearPointerSelection();
    }

    if (prepared.source != .mouse and prepared.restore_viewport) {
        var viewport: set_pane_viewport.SetPaneViewportHandler = .{
            .model = handler.model,
            .effects = handler.effects.viewport,
        };
        _ = try viewport.execute(.{
            .pane_id = plan.pane_id,
            .target = .bottom,
        });
    }

    try handler.effects.send(handler.effects.context, .{
        .pane_id = plan.pane_id,
        .bytes = prepared.bytes,
    });

    return .{
        .pane_id = plan.pane_id,
        .byte_count = prepared.bytes.len,
        .source = prepared.source,
    };
}
