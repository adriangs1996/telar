//! Application use case for delivering semantic user input to one pane.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../../../input/root.zig");
const client_model = @import("../../model/root.zig");
const set_pane_viewport = @import("../panes/set_pane_viewport.zig");

const host_input = input_capability.host;
const keybind = input_capability.keybind;
const schema = core.schema;

pub const max_bytes: usize = 8 * 1024;
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

pub const Command = struct {
    target: client_model.PaneInputTarget,
    source: Source,
    payload: Payload,
};

pub const PasteMarker = enum {
    start,
    finish,
};

pub const PasteMarkerCommand = struct {
    target: client_model.PaneInputTarget,
    marker: PasteMarker,
};

pub const PaneInputEffect = struct {
    pane_id: schema.PaneId,
    /// Borrowed only for the synchronous send effect.
    bytes: []const u8,
};

pub const Delivery = struct {
    pane_id: schema.PaneId,
    byte_count: usize,
    source: Source,
};

pub const PaneInputEffects = struct {
    context: *anyopaque,
    send: *const fn (*anyopaque, PaneInputEffect) anyerror!void,
    viewport: set_pane_viewport.PaneViewportEffects,
};

pub const PaneInputHandler = struct {
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
                .bytes = try host_input.encodeKey(&encoded, value, plan.input_modes),
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
    pub fn executeKeys(handler: *PaneInputHandler, target: client_model.PaneInputTarget, keys: []const keybind.Key) !?Delivery {
        if (keys.len == 0 or keys.len > max_keys) {
            return error.InvalidInputLength;
        }

        const plan = handler.model.planPaneInput(target) orelse return null;
        var encoded: [max_bytes]u8 = undefined;
        var len: usize = 0;
        for (keys) |key| {
            var key_bytes: [32]u8 = undefined;
            const bytes = try host_input.encodeKey(&key_bytes, key, plan.input_modes);
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
        if (text.len > max_bytes - framing_bytes) {
            return error.InvalidInputLength;
        }

        var encoded: [max_bytes]u8 = undefined;
        const bytes = try host_input.encodePaste(&encoded, text, plan.input_modes);

        return try handler.deliver(plan, .{
            .source = .paste,
            .bytes = bytes,
        });
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
        source: Source,
        bytes: []const u8,
        restore_viewport: bool = true,
        empty_is_noop: bool = false,
    };

    fn deliver(handler: *PaneInputHandler, plan: client_model.PaneInputPlan, prepared: Prepared) !Delivery {
        if (prepared.bytes.len == 0 or prepared.bytes.len > max_bytes) {
            return error.InvalidInputLength;
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
};

const TestingModel = struct {
    model: *client_model.Model,
    pane_id: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        const pane_id: schema.PaneId = @enumFromInt(1);
        try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 10, .rows = 5 } });
        const pane = model.workspace.findPane(pane_id).?;
        pane.scroll = .{ .total_rows = 20, .offset = 10 };
        pane.input_modes.cursor_keys = true;

        return .{ .model = model, .pane_id = pane_id };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const EffectEvent = enum {
    viewport,
    input,
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    events: [2]EffectEvent = undefined,
    event_count: usize = 0,
    viewport_calls: usize = 0,
    input_calls: usize = 0,
    viewport_observed_commit: bool = false,
    input_observed_bottom: bool = false,
    pane_id: ?schema.PaneId = null,
    input: [64]u8 = undefined,
    input_len: usize = 0,
    fail_viewport: bool = false,
    fail_input: bool = false,

    fn port(capture: *EffectsCapture) PaneInputEffects {
        return .{
            .context = capture,
            .send = send,
            .viewport = .{
                .context = capture,
                .sync = syncViewport,
            },
        };
    }

    fn record(capture: *EffectsCapture, event: EffectEvent) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn syncViewport(context: *anyopaque, change: client_model.PaneViewportChange) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        const pane = capture.model.workspace.activeConst().?.model.findConst(change.pane_id).?;
        capture.record(.viewport);
        capture.viewport_calls += 1;
        capture.viewport_observed_commit = pane.scroll.offset == change.offset and
            capture.model.version().viewport == change.viewport_revision;

        if (capture.fail_viewport) {
            return error.ViewportSyncFailed;
        }
    }

    fn send(context: *anyopaque, effect: PaneInputEffect) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        const pane = capture.model.workspace.activeConst().?.model.findConst(effect.pane_id).?;
        capture.record(.input);
        capture.input_calls += 1;
        capture.input_observed_bottom = pane.scroll.atBottom(pane.buffer.h);
        capture.pane_id = effect.pane_id;
        capture.input_len = effect.bytes.len;
        @memcpy(capture.input[0..effect.bytes.len], effect.bytes);

        if (capture.fail_input) {
            return error.InputDeliveryFailed;
        }
    }
};

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
