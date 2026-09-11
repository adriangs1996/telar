//! Application use case for delivering semantic user input to one pane.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../../input/root.zig");
const client_model = @import("../../root.zig").model;
const set_pane_viewport = @import("../panes/root.zig").set_pane_viewport;

pub const host_input = input_capability.encoding;
pub const keybind = input_capability.keybind;
pub const schema = core.schema;

pub const max_bytes = input_capability.max_encoded_bytes;
/// Keys one synthetic sequence may carry; each key encodes to at most 32 bytes.
pub const max_keys: usize = max_bytes / 32;

pub const Source = enum {
    host,
    paste,
    mouse,
};

pub const Payload = union(enum) {
    bytes: []const u8,
    key: keybind.Key,
};

pub const Command = @import("PaneInputCommand.zig");

pub const PasteMarker = enum {
    start,
    finish,
};

pub const PasteMarkerCommand = @import("PasteMarkerCommand.zig");

pub const PaneInputEffect = @import("PaneInputEffect.zig");

pub const Delivery = @import("Delivery.zig");

pub const PaneInputEffects = @import("PaneInputEffects.zig");

pub const PaneInputHandler = @import("PaneInputHandler.zig");

/// Rejects terminal controls and unframed multiline text before history can send input.
/// Example: `try validateHistoryText(command, modes.bracketed_paste);`.
pub fn validateHistoryText(text: []const u8, bracketed_paste: bool) !void {
    if (text.len == 0 or text.len > schema.max_history_command_bytes) {
        return error.InvalidInputLength;
    }

    const view = std.unicode.Utf8View.init(text) catch return error.UnsafeHistoryText;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == '\n' or codepoint == '\t') {
            if (!bracketed_paste) {
                return error.UnframedHistoryText;
            }

            continue;
        }

        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) {
            return error.UnsafeHistoryText;
        }
    }
}

test "history paste cannot smuggle terminal keys or escape its bracketed boundary" {
    try validateHistoryText("echo café", false);
    try validateHistoryText("echo first\necho second", true);
    try std.testing.expectError(error.UnframedHistoryText, validateHistoryText("echo first\necho second", false));
    try std.testing.expectError(error.UnsafeHistoryText, validateHistoryText("echo x\x1b[201~\r", true));
    try std.testing.expectError(error.UnsafeHistoryText, validateHistoryText("echo x\x03", false));
    try std.testing.expectError(error.UnsafeHistoryText, validateHistoryText("echo \xc2\x9b", true));
}

const TestingModel = @import("PaneInputTestingModel.zig");

pub const EffectEvent = enum {
    viewport,
    input,
};

const EffectsCapture = @import("PaneInputEffectsCapture.zig");

test "PaneInputHandler encodes keys after resolution and restores live output" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: PaneInputHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const delivery = (try handler.execute(.{
        .target = .focused,
        .source = .host,
        .payload = .{ .key = try keybind.parseKey("left") },
    })).?;

    try std.testing.expectEqualSlices(EffectEvent, &.{ .viewport, .input }, capture.events[0..capture.event_count]);
    try std.testing.expect(capture.viewport_observed_commit);
    try std.testing.expect(capture.input_observed_bottom);
    try std.testing.expectEqualStrings("\x1bOD", capture.input[0..capture.input_len]);
    try std.testing.expectEqual(testing.pane_id, delivery.pane_id);
    try std.testing.expectEqual(@as(usize, 3), delivery.byte_count);
    try std.testing.expectEqual(Source.host, delivery.source);
    try std.testing.expectEqual(client_model.Version{ .viewport = 1 }, testing.model.version());
}

test "PaneInputHandler sends synthetic marker editing as one transaction" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: PaneInputHandler = .{ .model = testing.model, .effects = capture.port() };
    const keys = [_]keybind.Key{
        .{ .code = .left },
        .{ .code = .backspace },
        .{ .code = .right },
    };

    const delivery = (try handler.executeKeys(.{ .pane = testing.pane_id }, &keys)).?;

    try std.testing.expectEqual(@as(usize, 1), capture.input_calls);
    try std.testing.expectEqualStrings("\x1bOD\x7f\x1bOC", capture.input[0..capture.input_len]);
    try std.testing.expectEqual(@as(usize, 7), delivery.byte_count);
}

test "PaneInputHandler drops legacy releases without changing the viewport" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: PaneInputHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const delivery = try handler.execute(.{
        .target = .{ .key_lease = testing.pane_id },
        .source = .host,
        .payload = .{ .key = .{
            .code = .left,
            .phase = .release,
            .physical = .{ .value = 1 },
        } },
    });

    try std.testing.expect(delivery == null);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqual(@as(u64, 0), testing.model.version().viewport);
}

test "PaneInputHandler sends Kitty releases without restoring the viewport" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    testing.model.workspace.findPane(testing.pane_id).?.input_modes.kitty_keyboard_flags = 2;
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: PaneInputHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const delivery = (try handler.execute(.{
        .target = .{ .key_lease = testing.pane_id },
        .source = .host,
        .payload = .{ .key = .{
            .code = .left,
            .phase = .release,
            .physical = .{ .value = 1 },
        } },
    })).?;

    try std.testing.expectEqualSlices(EffectEvent, &.{.input}, capture.events[0..capture.event_count]);
    try std.testing.expectEqualStrings("\x1b[1;1:3D", capture.input[0..capture.input_len]);
    try std.testing.expectEqual(@as(u64, 0), testing.model.version().viewport);
    try std.testing.expectEqual(testing.pane_id, delivery.pane_id);
}

test "PaneInputHandler restores paste input but preserves viewport for mouse reports" {
    var paste_testing = try TestingModel.init();
    defer paste_testing.deinit();
    var paste_capture: EffectsCapture = .{ .model = paste_testing.model };
    var paste_handler: PaneInputHandler = .{
        .model = paste_testing.model,
        .effects = paste_capture.port(),
    };

    _ = try paste_handler.execute(.{
        .target = .focused,
        .source = .paste,
        .payload = .{ .bytes = "pasted" },
    });

    try std.testing.expectEqualSlices(EffectEvent, &.{ .viewport, .input }, paste_capture.events[0..paste_capture.event_count]);
    try std.testing.expectEqual(@as(u32, 15), paste_testing.model.workspace.findPane(paste_testing.pane_id).?.scroll.offset);

    var mouse_testing = try TestingModel.init();
    defer mouse_testing.deinit();
    var mouse_capture: EffectsCapture = .{ .model = mouse_testing.model };
    var mouse_handler: PaneInputHandler = .{
        .model = mouse_testing.model,
        .effects = mouse_capture.port(),
    };

    const delivery = (try mouse_handler.execute(.{
        .target = .{ .pane = mouse_testing.pane_id },
        .source = .mouse,
        .payload = .{ .bytes = "\x1b[<0;1;1M" },
    })).?;

    try std.testing.expectEqualSlices(EffectEvent, &.{.input}, mouse_capture.events[0..mouse_capture.event_count]);
    try std.testing.expectEqual(@as(u32, 10), mouse_testing.model.workspace.findPane(mouse_testing.pane_id).?.scroll.offset);
    try std.testing.expectEqualDeep(client_model.Version{}, mouse_testing.model.version());
    try std.testing.expectEqual(Source.mouse, delivery.source);
}

test "PaneInputHandler frames expression paste inside the application boundary" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    testing.model.workspace.findPane(testing.pane_id).?.input_modes.bracketed_paste = true;
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: PaneInputHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const delivery = (try handler.executePaste(.focused, "pasted")).?;

    try std.testing.expectEqualSlices(EffectEvent, &.{ .viewport, .input }, capture.events[0..capture.event_count]);
    try std.testing.expectEqualStrings("\x1b[200~pasted\x1b[201~", capture.input[0..capture.input_len]);
    try std.testing.expectEqual(@as(usize, 18), delivery.byte_count);
    try std.testing.expectEqual(Source.paste, delivery.source);
}

test "history execution sends Enter after the bracketed paste terminator" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    testing.model.workspace.findPane(testing.pane_id).?.input_modes.bracketed_paste = true;
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: PaneInputHandler = .{ .model = testing.model, .effects = capture.port() };
    _ = try handler.executeHistoryPaste(.{ .target = .focused, .text = "echo hello", .run = true });
    try std.testing.expectEqualStrings("\x1b[200~echo hello\x1b[201~\r", capture.input[0..capture.input_len]);
}

test "PaneInputHandler delivers an explicit paste marker independently of current mode" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: PaneInputHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const delivery = (try handler.executePasteMarker(.{
        .target = .focused,
        .marker = .start,
    })).?;

    try std.testing.expectEqual(testing.pane_id, delivery.pane_id);
    try std.testing.expectEqualStrings("\x1b[200~", capture.input[0..capture.input_len]);
    try std.testing.expectEqualSlices(EffectEvent, &.{ .viewport, .input }, capture.events[0..capture.event_count]);
    try std.testing.expectEqual(@as(u32, 15), testing.model.workspace.findPane(testing.pane_id).?.scroll.offset);
    try std.testing.expectEqual(client_model.Version{ .viewport = 1 }, testing.model.version());
}

test "PaneInputHandler rejects invalid payloads before viewport or delivery effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: PaneInputHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    const oversized = [_]u8{'x'} ** (max_bytes + 1);

    try std.testing.expectError(error.InvalidInputLength, handler.execute(.{
        .target = .focused,
        .source = .host,
        .payload = .{ .bytes = "" },
    }));
    try std.testing.expectError(error.InvalidInputLength, handler.execute(.{
        .target = .focused,
        .source = .paste,
        .payload = .{ .bytes = &oversized },
    }));
    try std.testing.expectError(error.InvalidInputLength, handler.executePaste(.focused, &oversized));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqual(@as(u32, 10), testing.model.workspace.findPane(testing.pane_id).?.scroll.offset);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "PaneInputHandler suppresses unavailable and exclusively owned targets" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: PaneInputHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    testing.model.workspace.findPane(testing.pane_id).?.attached = false;
    try std.testing.expect((try handler.execute(.{
        .target = .focused,
        .source = .host,
        .payload = .{ .bytes = "x" },
    })) == null);
    testing.model.workspace.findPane(testing.pane_id).?.attached = true;
    try std.testing.expect(testing.model.enterCopyMode());
    const version = testing.model.version();
    try std.testing.expect((try handler.execute(.{
        .target = .{ .pane = testing.pane_id },
        .source = .paste,
        .payload = .{ .bytes = "x" },
    })) == null);

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "PaneInputHandler does not deliver when viewport synchronization fails" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model, .fail_viewport = true };
    var handler: PaneInputHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.ViewportSyncFailed, handler.execute(.{
        .target = .focused,
        .source = .host,
        .payload = .{ .bytes = "x" },
    }));

    try std.testing.expectEqualSlices(EffectEvent, &.{.viewport}, capture.events[0..capture.event_count]);
    try std.testing.expectEqual(@as(usize, 0), capture.input_calls);
    try std.testing.expectEqual(@as(u32, 15), testing.model.workspace.findPane(testing.pane_id).?.scroll.offset);
    try std.testing.expectEqual(client_model.Version{ .viewport = 1 }, testing.model.version());
}

test "PaneInputHandler preserves a restored viewport when delivery fails" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model, .fail_input = true };
    var handler: PaneInputHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.InputDeliveryFailed, handler.execute(.{
        .target = .focused,
        .source = .paste,
        .payload = .{ .bytes = "x" },
    }));

    try std.testing.expectEqualSlices(EffectEvent, &.{ .viewport, .input }, capture.events[0..capture.event_count]);
    try std.testing.expect(capture.input_observed_bottom);
    try std.testing.expectEqual(@as(u32, 15), testing.model.workspace.findPane(testing.pane_id).?.scroll.offset);
    try std.testing.expectEqual(client_model.Version{ .viewport = 1 }, testing.model.version());
}
