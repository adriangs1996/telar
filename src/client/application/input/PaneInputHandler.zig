const HistoryPasteType = @import("HistoryPaste.zig");
const ModelType = @import("../../model/Model.zig");
const PaneInputEffects = @import("PaneInputEffects.zig");
const PaneInputCommand = @import("PaneInputCommand.zig");
const Delivery = @import("PaneInputDelivery.zig");
const Prepared = @import("Prepared.zig");
const encoding_support = @import("../../input/encoding_support.zig");
const types = @import("../../model/types.zig");
const KeyType = @import("../../input/Key.zig");
const pane_input = @import("pane_input.zig");
const root = @import("../../input/input_namespace.zig");
const max_history_command_bytes_module = @import("telar-core").max_history_command_bytes;
const PasteMarkerCommand = @import("PasteMarkerCommand.zig");
const PaneInputPlanType = @import("../../model/PaneInputPlan.zig");
const SetPaneViewportHandlerType = @import("../panes/SetPaneViewportHandler.zig");
const PaneInputHandler = @This();

model: *ModelType,
effects: PaneInputEffects,

/// Encodes semantic keys before any commit, restores live output for key
/// presses, repeats and paste, then delivers bytes to the resolved pane.
/// Releases and mouse reports preserve the user's current viewport.
///
/// ```zig
/// const delivery = try handler.execute(command) orelse return;
/// ```
pub fn execute(handler: *PaneInputHandler, command: PaneInputCommand) !?Delivery {
    const plan = handler.model.planPaneInput(command.target) orelse return null;
    var encoded: [32]u8 = undefined;
    const prepared: Prepared = switch (command.payload) {
        .bytes => |value| .{ .source = command.source, .bytes = value },
        .key => |value| .{
            .source = command.source,
            .bytes = try encoding_support.encodeKey(&encoded, value, plan.input_modes),
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
pub fn executeKeys(handler: *PaneInputHandler, target: types.PaneInputTarget, keys: []const KeyType) !?Delivery {
    if (keys.len == 0 or keys.len > pane_input.max_keys) {
        return error.InvalidInputLength;
    }

    const plan = handler.model.planPaneInput(target) orelse return null;
    var encoded: [root.max_encoded_bytes]u8 = undefined;
    var len: usize = 0;
    for (keys) |key| {
        var key_bytes: [32]u8 = undefined;
        const bytes = try encoding_support.encodeKey(&key_bytes, key, plan.input_modes);
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
pub fn executePaste(handler: *PaneInputHandler, target: types.PaneInputTarget, text: []const u8) !?Delivery {
    const plan = handler.model.planPaneInput(target) orelse return null;
    const framing_bytes: usize = if (plan.input_modes.bracketed_paste) 12 else 0;
    if (text.len > root.max_encoded_bytes - framing_bytes) {
        return error.InvalidInputLength;
    }

    var encoded: [root.max_encoded_bytes]u8 = undefined;
    const bytes = try encoding_support.encodePaste(&encoded, text, plan.input_modes);

    return try handler.deliver(plan, .{
        .source = .paste,
        .bytes = bytes,
    });
}

pub const HistoryPaste = @import("HistoryPaste.zig");

/// Frames a complete history command and puts execution after the paste boundary.
/// The send port must atomically reserve the resulting bounded input batch.
/// Example: `_ = try handler.executeHistoryPaste(.{ .target = .focused, .text = command, .run = false });`.
pub fn executeHistoryPaste(handler: *PaneInputHandler, request: HistoryPasteType) !?Delivery {
    const plan = handler.model.planPaneInput(request.target) orelse return null;
    try pane_input.validateHistoryText(request.text, plan.input_modes.bracketed_paste);
    var encoded: [max_history_command_bytes_module + 13]u8 = undefined;
    const paste = try encoding_support.encodePaste(&encoded, request.text, plan.input_modes);
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

fn deliver(handler: *PaneInputHandler, plan: PaneInputPlanType, prepared: Prepared) !Delivery {
    if (prepared.bytes.len == 0 or prepared.bytes.len > prepared.limit) {
        return error.InvalidInputLength;
    }

    if (prepared.source != .mouse) {
        _ = handler.model.clearPointerSelection();
    }

    if (prepared.source != .mouse and prepared.restore_viewport) {
        var viewport: SetPaneViewportHandlerType = .{
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
