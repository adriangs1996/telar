//! Application policy for one streamed host paste owned by a pane.

const PanePasteSessionType = @import("../../model/PanePasteSession.zig");
const PanePasteTestingModel = @import("PanePasteTestingModel.zig");
const PanePasteCapture = @import("PanePasteCapture.zig");
const PanePasteHandler = @import("PanePasteHandler.zig");
const std = @import("std");

pub const Boundary = enum {
    start,
    finish,
};

pub const Delivery = union(enum) {
    marker: struct {
        session: PanePasteSessionType,
        boundary: Boundary,
    },
    content: struct {
        session: PanePasteSessionType,
        /// Borrowed only for the synchronous delivery effect.
        text: []const u8,
    },
};

pub const Outcome = enum {
    applied,
    unavailable,
    ignored,
};

test "PanePasteHandler preserves captured identity and framing through finish" {
    var testing = try PanePasteTestingModel.init(true);
    defer testing.deinit();
    const version = testing.model.version();
    var capture: PanePasteCapture = .{ .model = testing.model };
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
    var testing = try PanePasteTestingModel.init(false);
    defer testing.deinit();
    var capture: PanePasteCapture = .{ .model = testing.model };
    var handler: PanePasteHandler = .{ .model = testing.model, .effects = capture.port() };

    try std.testing.expect(try handler.start() == .applied);
    try std.testing.expect(try handler.content("one") == .applied);
    try std.testing.expect(try handler.finish() == .applied);

    try std.testing.expectEqual(@as(usize, 1), capture.delivery_count);
    try std.testing.expect(capture.deliveries[0] == .content);
    try std.testing.expect(!testing.model.panePasteActive());
}

test "PanePasteHandler rolls back every failed start path" {
    var unavailable = try PanePasteTestingModel.init(true);
    defer unavailable.deinit();
    var unavailable_capture: PanePasteCapture = .{ .model = unavailable.model, .available = false };
    var unavailable_handler: PanePasteHandler = .{
        .model = unavailable.model,
        .effects = unavailable_capture.port(),
    };

    try std.testing.expect(try unavailable_handler.start() == .unavailable);
    try std.testing.expect(!unavailable.model.panePasteActive());

    var failed = try PanePasteTestingModel.init(true);
    defer failed.deinit();
    var failed_capture: PanePasteCapture = .{ .model = failed.model, .fail = true };
    var failed_handler: PanePasteHandler = .{ .model = failed.model, .effects = failed_capture.port() };

    try std.testing.expectError(error.PasteDeliveryFailed, failed_handler.start());
    try std.testing.expect(!failed.model.panePasteActive());
}

test "PanePasteHandler retains failed content but always clears failed finish" {
    var testing = try PanePasteTestingModel.init(true);
    defer testing.deinit();
    var capture: PanePasteCapture = .{ .model = testing.model };
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
