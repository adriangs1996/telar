//! Application policy for one streamed host paste owned by a pane.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model.zig");

const schema = core.schema;

pub const Boundary = enum {
    start,
    finish,
};

pub const Delivery = union(enum) {
    marker: struct {
        session: client_model.PanePasteSession,
        boundary: Boundary,
    },
    content: struct {
        session: client_model.PanePasteSession,
        /// Borrowed only for the synchronous delivery effect.
        text: []const u8,
    },
};

pub const Effects = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, Delivery) anyerror!bool,
};

pub const Outcome = enum {
    applied,
    unavailable,
    ignored,
};

pub const PanePasteHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Captures one pane and rolls the session back when its opening marker
    /// cannot enter the pane-input path.
    ///
    /// ```zig
    /// _ = try handler.start();
    /// ```
    pub fn start(handler: *PanePasteHandler) !Outcome {
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
    pub fn content(handler: *PanePasteHandler, text: []const u8) !Outcome {
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
    pub fn finish(handler: *PanePasteHandler) !Outcome {
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
};

const TestingModel = struct {
    model: *client_model.Model,
    pane_id: schema.PaneId,

    fn init(bracketed_paste: bool) !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const pane_id: schema.PaneId = @enumFromInt(1);
        try model.workspace.bootstrap(pane_id, .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        }, .{ .cols = 20, .rows = 5 });
        model.workspace.findPane(pane_id).?.input_modes.bracketed_paste = bracketed_paste;

        return .{ .model = model, .pane_id = pane_id };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const Capture = struct {
    model: *const client_model.Model,
    deliveries: [4]Delivery = undefined,
    delivery_count: usize = 0,
    all_observed_active: bool = true,
    available: bool = true,
    fail: bool = false,

    fn port(capture: *Capture) Effects {
        return .{ .context = capture, .deliver = deliver };
    }

    fn deliver(raw_context: *anyopaque, delivery: Delivery) !bool {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.all_observed_active = capture.all_observed_active and capture.model.panePasteActive();
        capture.deliveries[capture.delivery_count] = delivery;
        capture.delivery_count += 1;
        if (capture.fail) {
            return error.PasteDeliveryFailed;
        }

        return capture.available;
    }
};

test "PanePasteHandler preserves captured identity and framing through finish" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const version = testing.model.version();
    var capture: Capture = .{ .model = testing.model };
    var handler: PanePasteHandler = .{ .model = testing.model, .effects = capture.port() };

    try std.testing.expect(try handler.start() == .applied);
    testing.model.workspace.findPane(testing.pane_id).?.input_modes.bracketed_paste = false;
    try std.testing.expect(try handler.content("one") == .applied);
    try std.testing.expect(try handler.finish() == .applied);

    try std.testing.expectEqual(@as(usize, 3), capture.delivery_count);
    try std.testing.expect(capture.all_observed_active);
    try std.testing.expect(capture.deliveries[0] == .marker);
    try std.testing.expect(capture.deliveries[0].marker.boundary == .start);
    try std.testing.expect(capture.deliveries[0].marker.session.bracketed_paste);
    try std.testing.expect(capture.deliveries[1] == .content);
    try std.testing.expectEqualStrings("one", capture.deliveries[1].content.text);
    try std.testing.expectEqual(testing.pane_id, capture.deliveries[1].content.session.pane_id);
    try std.testing.expect(capture.deliveries[2] == .marker);
    try std.testing.expect(capture.deliveries[2].marker.boundary == .finish);
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "PanePasteHandler omits markers for a captured unframed session" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    var capture: Capture = .{ .model = testing.model };
    var handler: PanePasteHandler = .{ .model = testing.model, .effects = capture.port() };

    try std.testing.expect(try handler.start() == .applied);
    try std.testing.expect(try handler.content("one") == .applied);
    try std.testing.expect(try handler.finish() == .applied);

    try std.testing.expectEqual(@as(usize, 1), capture.delivery_count);
    try std.testing.expect(capture.deliveries[0] == .content);
    try std.testing.expect(!testing.model.panePasteActive());
}

test "PanePasteHandler rolls back every failed start path" {
    var unavailable = try TestingModel.init(true);
    defer unavailable.deinit();
    var unavailable_capture: Capture = .{ .model = unavailable.model, .available = false };
    var unavailable_handler: PanePasteHandler = .{
        .model = unavailable.model,
        .effects = unavailable_capture.port(),
    };

    try std.testing.expect(try unavailable_handler.start() == .unavailable);
    try std.testing.expect(!unavailable.model.panePasteActive());

    var failed = try TestingModel.init(true);
    defer failed.deinit();
    var failed_capture: Capture = .{ .model = failed.model, .fail = true };
    var failed_handler: PanePasteHandler = .{ .model = failed.model, .effects = failed_capture.port() };

    try std.testing.expectError(error.PasteDeliveryFailed, failed_handler.start());
    try std.testing.expect(!failed.model.panePasteActive());
}

test "PanePasteHandler retains failed content but always clears failed finish" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: Capture = .{ .model = testing.model };
    var handler: PanePasteHandler = .{ .model = testing.model, .effects = capture.port() };

    try std.testing.expect(try handler.start() == .applied);
    capture.available = false;
    try std.testing.expect(try handler.content("one") == .unavailable);
    try std.testing.expect(testing.model.panePasteActive());
    capture.fail = true;
    try std.testing.expectError(error.PasteDeliveryFailed, handler.finish());

    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(try handler.finish() == .ignored);
}
