//! Application boundary for client-owned copy mode.

const CopyModeTestingModel = @import("CopyModeTestingModel.zig");
const CopyModeEffectsCapture = @import("CopyModeEffectsCapture.zig");
const CopyModeHandler = @import("CopyModeHandler.zig");
const types = @import("../../model/types.zig");
const std = @import("std");
const chord = @import("../../input/chord.zig");

pub const Outcome = enum {
    unchanged,
    changed,
    exited,
};

test "mouse clicks expand words and lines and copy only once on release" {
    var testing = try CopyModeTestingModel.init();
    defer testing.deinit();
    var capture: CopyModeEffectsCapture = .{ .model = testing.model };
    var handler: CopyModeHandler = .{ .model = testing.model, .effects = capture.port() };
    const pane = testing.model.workspace.findPane(testing.pane_id).?;
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "one two", .style = .{} });
    const release: types.CopyModeCommand = .{ .pointer = .{ .position = .{ .x = 5, .y = 0 }, .release = true } };

    for (0..3) |index| {
        try std.testing.expect(handler.beginPointer(.{
            .pane_id = testing.pane_id,
            .position = release.pointer.position,
            .now_ns = index * std.time.ns_per_ms,
        }));
        try std.testing.expect(!testing.model.copyModeActive());
        _ = try handler.execute(release);
        if (index == 0) {
            try std.testing.expect(testing.model.pointerSelection() == null);
            try std.testing.expectEqual(@as(usize, 0), capture.copy_calls);
            continue;
        }

        try std.testing.expect(!testing.model.pointerSelection().?.dragging);
        try std.testing.expectEqual(@as(u32, 10), capture.copied.?.start_y);
        try std.testing.expectEqual(@as(u16, if (index == 1) 4 else 0), capture.copied.?.start_x);
        try std.testing.expectEqual(@as(u16, if (index == 1) 6 else 9), capture.copied.?.end_x);
        try std.testing.expectEqual(index == 2, capture.copied.?.linewise);
        try std.testing.expectEqual(index, capture.copy_calls);
        try std.testing.expectEqual(Outcome.unchanged, try handler.execute(release));
        try std.testing.expectEqual(index, capture.copy_calls);
    }

    try std.testing.expectEqual(@as(usize, 0), capture.viewport_calls);
}

test "failed mouse copy retains highlighting but releases physical capture" {
    var testing = try CopyModeTestingModel.init();
    defer testing.deinit();
    var capture: CopyModeEffectsCapture = .{ .model = testing.model, .fail_copy = true };
    var handler: CopyModeHandler = .{ .model = testing.model, .effects = capture.port() };
    try std.testing.expect(handler.beginPointer(.{
        .pane_id = testing.pane_id,
        .position = .{ .x = 1, .y = 1 },
        .now_ns = 0,
    }));
    _ = try handler.execute(.{ .pointer = .{ .position = .{ .x = 4, .y = 1 } } });
    const version = testing.model.version();
    const projection = testing.model.copyModeProjection();

    try std.testing.expectError(error.CopyDeliveryFailed, handler.execute(.{ .pointer = .{
        .position = .{ .x = 4, .y = 1 },
        .release = true,
    } }));
    try std.testing.expectEqualDeep(version, testing.model.version());
    try std.testing.expectEqualDeep(projection, testing.model.copyModeProjection());
    try std.testing.expect(!testing.model.pointerSelection().?.dragging);
    try std.testing.expectEqual(@as(usize, 0), capture.viewport_calls);
}

test "CopyModeHandler copies before exit and synchronizes the committed viewport" {
    var testing = try CopyModeTestingModel.init();
    defer testing.deinit();
    var capture: CopyModeEffectsCapture = .{ .model = testing.model };
    var handler: CopyModeHandler = .{ .model = testing.model, .effects = capture.port() };

    try std.testing.expect(handler.enter());
    try std.testing.expect(try handler.execute(.{ .key = try chord.parseKey("v") }) == .changed);
    try std.testing.expect(try handler.execute(.{ .key = try chord.parseKey("g") }) == .changed);
    try std.testing.expectEqual(@as(u32, 0), testing.model.workspace.findPane(testing.pane_id).?.scroll.offset);
    capture.reset();

    try std.testing.expect(try handler.execute(.{ .key = try chord.parseKey("enter") }) == .exited);

    try std.testing.expectEqual(@as(usize, 1), capture.copy_calls);
    try std.testing.expect(capture.copy_observed_active);
    try std.testing.expectEqual(testing.pane_id, capture.copied.?.pane_id);
    try std.testing.expectEqual(@as(u32, 14), capture.copied.?.start_y);
    try std.testing.expectEqual(@as(u32, 0), capture.copied.?.end_y);
    try std.testing.expectEqual(@as(usize, 1), capture.viewport_calls);
    try std.testing.expect(capture.viewport_observed_commit);
    try std.testing.expect(!capture.viewport_observed_active);
    try std.testing.expectEqual(@as(u32, 10), capture.viewport.?.offset);
    try std.testing.expectEqual(@as(u64, 2), capture.viewport.?.viewport_revision);
    try std.testing.expectEqual(@as(u64, 2), testing.model.version().viewport);
    try std.testing.expect(!testing.model.copyModeActive());
}

test "CopyModeHandler retains selection and revision when copy delivery fails" {
    var testing = try CopyModeTestingModel.init();
    defer testing.deinit();
    var capture: CopyModeEffectsCapture = .{ .model = testing.model, .fail_copy = true };
    var handler: CopyModeHandler = .{ .model = testing.model, .effects = capture.port() };
    try std.testing.expect(handler.enter());
    try std.testing.expect(try handler.execute(.{ .key = try chord.parseKey("v") }) == .changed);
    const version = testing.model.version();

    try std.testing.expectError(
        error.CopyDeliveryFailed,
        handler.execute(.{ .key = try chord.parseKey("enter") }),
    );

    try std.testing.expect(testing.model.copyModeActive());
    try std.testing.expectEqualDeep(version, testing.model.version());
    try std.testing.expectEqual(@as(usize, 1), capture.copy_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.viewport_calls);
}

test "CopyModeHandler opens a link without committing or leaving copy mode" {
    var testing = try CopyModeTestingModel.init();
    defer testing.deinit();
    const pane = testing.model.workspace.findPane(testing.pane_id).?;
    try pane.buffer.resize(40, 5);
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 4 }, .text = "https://example.com/path", .style = .{} });
    pane.cursor = .{ .visible = true, .x = 10, .y = 4 };

    var capture: CopyModeEffectsCapture = .{ .model = testing.model };
    var handler: CopyModeHandler = .{ .model = testing.model, .effects = capture.port() };
    try std.testing.expect(handler.enter());
    const version = testing.model.version();

    try std.testing.expectEqual(Outcome.unchanged, try handler.execute(.{ .key = try chord.parseKey("o") }));

    try std.testing.expectEqualStrings("https://example.com/path", capture.link_opened.?.uri());
    try std.testing.expect(testing.model.copyModeActive());
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "CopyModeHandler preserves a movement commit when viewport sync fails" {
    var testing = try CopyModeTestingModel.init();
    defer testing.deinit();
    var capture: CopyModeEffectsCapture = .{ .model = testing.model, .fail_viewport = true };
    var handler: CopyModeHandler = .{ .model = testing.model, .effects = capture.port() };
    try std.testing.expect(handler.enter());
    const version = testing.model.version();

    try std.testing.expectError(
        error.ViewportSyncFailed,
        handler.execute(.{ .key = try chord.parseKey("g") }),
    );

    try std.testing.expect(testing.model.copyModeActive());
    try std.testing.expectEqual(version.copy + 1, testing.model.version().copy);
    try std.testing.expectEqual(version.viewport + 1, testing.model.version().viewport);
    try std.testing.expectEqual(@as(u32, 0), testing.model.workspace.findPane(testing.pane_id).?.scroll.offset);
    try std.testing.expect(capture.viewport_observed_commit);
    try std.testing.expect(capture.viewport_observed_active);
}

test "CopyModeHandler suppresses boundary and unhandled no-ops" {
    var testing = try CopyModeTestingModel.init();
    defer testing.deinit();
    var capture: CopyModeEffectsCapture = .{ .model = testing.model };
    var handler: CopyModeHandler = .{ .model = testing.model, .effects = capture.port() };
    try std.testing.expect(handler.enter());
    const version = testing.model.version();

    try std.testing.expect(try handler.execute(.{ .key = try chord.parseKey("left") }) == .unchanged);
    try std.testing.expect(try handler.execute(.{ .key = try chord.parseKey("z") }) == .unchanged);

    try std.testing.expectEqualDeep(version, testing.model.version());
    try std.testing.expectEqual(@as(usize, 0), capture.copy_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.viewport_calls);
}
