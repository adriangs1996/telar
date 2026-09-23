//! Local clipboard capture and bounded client-owned image previews.
//!
//! Clipboard access runs only in a concurrent media task. The interactive
//! path forwards the triggering key before it schedules that task. Captured
//! bytes are disposable presentation state: the agent remains the authority
//! for whether an attachment was accepted.

const data = @import("model");
const client = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");
const delivery = @import("delivery.zig");
const kitty_codec = @import("../graphics/kitty_codec.zig");

fn optionalTargetEql(a: ?data.AttachmentTarget, b: ?data.AttachmentTarget) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return std.meta.eql(a.?, b.?);
}

test {
    _ = @import("telar-client");
}

fn testCapture(gpa: std.mem.Allocator, request: data.CaptureRequest, bytes: []const u8) !*data.Capture {
    const capture = try gpa.create(data.Capture);
    errdefer gpa.destroy(capture);
    capture.* = .{
        .request = request,
        .png = try gpa.dupe(u8, bytes),
        .width = 20,
        .height = 10,
    };
    return capture;
}

fn testRequest(sequence: u64, target: data.AttachmentTarget) data.CaptureRequest {
    return .{
        .target = target,
        .sequence = sequence,
    };
}

test "preview store is bounded and keeps captures scoped to their agent generation" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt(7), .pane_generation = 3 };
    try std.testing.expect(store.setTarget(target).changed);
    for (1..6) |sequence| {
        try store.adopt(try testCapture(
            std.testing.allocator,
            testRequest(sequence, target),
            "png",
        ));
    }

    const snapshot = store.snapshot();
    try std.testing.expectEqual(@as(u8, data.attachment_types.max_items), snapshot.len);
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(snapshot.items[0].id));
    try std.testing.expectEqual(@as(u64, 5), @intFromEnum(snapshot.items[3].id));
    try std.testing.expectEqual(@as(usize, data.attachment_types.max_items * 3), store.retainedBytes());
    try std.testing.expectEqual(@as(u64, 5), store.ingressVersion());

    const other: data.AttachmentTarget = .{ .pane_id = target.pane_id, .pane_generation = 4 };
    const changed = store.setTarget(other);
    try std.testing.expect(changed.changed);
    try std.testing.expect(changed.layout_changed);
    try std.testing.expectEqual(@as(u8, 0), store.snapshot().len);
}

test "switching visible previews between panes changes their layout owner" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const first: data.AttachmentTarget = .{ .pane_id = @enumFromInt(7), .pane_generation = 3 };
    const second: data.AttachmentTarget = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(first);
    try store.adopt(try testCapture(std.testing.allocator, testRequest(1, first), "first"));
    try store.adopt(try testCapture(std.testing.allocator, testRequest(2, second), "second"));

    const changed = store.setTarget(second);

    try std.testing.expect(changed.changed);
    try std.testing.expect(changed.layout_changed);
    try std.testing.expectEqual(second, store.visibleTarget().?);
}

test "marker removal keeps preview order aligned with atomic child placeholders" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    try store.adopt(try testCapture(std.testing.allocator, testRequest(1, target), "first"));
    try store.adopt(try testCapture(std.testing.allocator, testRequest(2, target), "second"));
    var buffer = try core.Buffer.init(std.testing.allocator, 64, 2);
    defer buffer.deinit();
    const prompt = "> [Image #1]xx[Image #2]tail";
    const cursor_x = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = prompt, .style = .{} });
    const screen: client.MarkerScreen = .{
        .buffer = &buffer,
        .cursor = .{ .visible = true, .x = cursor_x, .y = 0 },
    };

    const removal = store.planMarkerRemoval(@enumFromInt(1), screen).?;

    try std.testing.expect(removal.direction == .left);
    try std.testing.expectEqual(@as(u8, 7), removal.steps);
    try std.testing.expect(removal.deletion == .backward);

    const second_end: u16 = 2 + client.minimum_marker_width + 2 + client.minimum_marker_width;
    try std.testing.expectEqual(
        @as(data.AttachmentId, @enumFromInt(2)),
        store.idAtMarkerDeletion(.{
            .buffer = &buffer,
            .cursor = .{ .visible = true, .x = second_end, .y = 0 },
        }, .backward).?,
    );
    try std.testing.expectEqual(
        @as(data.AttachmentId, @enumFromInt(1)),
        store.idAtMarkerDeletion(.{
            .buffer = &buffer,
            .cursor = .{ .visible = true, .x = 2, .y = 0 },
        }, .forward).?,
    );

    buffer.clear(.{});
    const pending_cursor = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "> [Image #1][Image #2][Image #3]", .style = .{} });
    try std.testing.expect(store.pendingMarkerAtDeletion(.{
        .buffer = &buffer,
        .cursor = .{ .visible = true, .x = pending_cursor, .y = 0 },
    }, .{ .deletion = .backward }));
}

test "Claude previews retain stable marker numbers across attachment deletion" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    const first = try testCapture(std.testing.allocator, testRequest(1, target), "first");
    first.request.marker_policy = .stable_number;
    try store.adopt(first);
    const second = try testCapture(std.testing.allocator, testRequest(2, target), "second");
    second.request.marker_policy = .stable_number;
    try store.adopt(second);
    var buffer = try core.Buffer.init(std.testing.allocator, 64, 2);
    defer buffer.deinit();
    var cursor_x = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "> [Image #7][Image #12]", .style = .{} });

    try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, .{
        .buffer = &buffer,
        .cursor = .{ .visible = true, .x = cursor_x, .y = 0 },
    }));
    const removal = store.planMarkerRemoval(@enumFromInt(1), .{
        .buffer = &buffer,
        .cursor = .{ .visible = true, .x = cursor_x, .y = 0 },
    }).?;
    try std.testing.expectEqual(@as(u8, 1), removal.steps);

    buffer.clear(.{});
    cursor_x = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "> [Image #12]", .style = .{} });
    store.expectMarkerDeletion(target);
    try std.testing.expectEqual(@as(u8, 1), store.reconcileMarkers(target, .{
        .buffer = &buffer,
        .cursor = .{ .visible = true, .x = cursor_x, .y = 0 },
    }));

    const remaining = store.snapshot();
    try std.testing.expectEqual(@as(u8, 1), remaining.len);
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(remaining.items[0].id));
}

test "a marker wrapped at its space keeps its preview and stays dismissable" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    const capture = try testCapture(std.testing.allocator, testRequest(1, target), "first");
    capture.request.marker_policy = .stable_number;
    try store.adopt(capture);
    var buffer = try core.Buffer.init(std.testing.allocator, 40, 3);
    defer buffer.deinit();
    _ = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "> aaaaaaaaaaaaaaaaaaaaaaaaaaaaa [Image", .style = .{} });
    const end_x = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 1 }, .text = "  #1]", .style = .{} });
    const after_marker: client.MarkerScreen = .{ .buffer = &buffer, .cursor = .{ .visible = true, .x = end_x, .y = 1 } };

    try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, after_marker));
    try std.testing.expectEqual(@as(?u16, 1), store.findConst(@enumFromInt(1)).?.markerNumber());

    store.expectMarkerDeletion(target);
    try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, after_marker));
    try std.testing.expectEqual(@as(u8, 1), store.snapshot().len);

    const backward = store.planMarkerRemoval(@enumFromInt(1), after_marker).?;
    try std.testing.expectEqual(data.AttachmentMarkerDeletion.backward, backward.deletion);
    try std.testing.expectEqual(@as(u8, 0), backward.steps);
    try std.testing.expectEqual(@as(?data.AttachmentId, @enumFromInt(1)), store.idAtMarkerDeletion(after_marker, .backward));

    const before_marker: client.MarkerScreen = .{ .buffer = &buffer, .cursor = .{ .visible = true, .x = 2, .y = 0 } };
    const forward = store.planMarkerRemoval(@enumFromInt(1), before_marker).?;
    try std.testing.expectEqual(data.AttachmentMarkerDeletion.forward, forward.deletion);
    try std.testing.expectEqual(@as(u8, 30), forward.steps);
    try std.testing.expectEqual(@as(?data.AttachmentId, @enumFromInt(1)), store.idAtMarkerDeletion(.{
        .buffer = &buffer,
        .cursor = .{ .visible = true, .x = 32, .y = 0 },
    }, .forward));

    buffer.clear(.{});
    _ = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "> aaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .style = .{} });
    store.expectMarkerDeletion(target);
    try std.testing.expectEqual(@as(u8, 1), store.reconcileMarkers(target, after_marker));
    try std.testing.expectEqual(@as(u8, 0), store.snapshot().len);
}

test "Enter after a trailing backslash continues the prompt" {
    var buffer = try core.Buffer.init(std.testing.allocator, 20, 2);
    defer buffer.deinit();
    const end_x = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "> hello\\", .style = .{} });

    try std.testing.expect(client.promptContinuesAtCursor(.{ .buffer = &buffer, .cursor = .{ .visible = true, .x = end_x, .y = 0 } }));
    try std.testing.expect(!client.promptContinuesAtCursor(.{ .buffer = &buffer, .cursor = .{ .visible = true, .x = end_x - 1, .y = 0 } }));
    try std.testing.expect(!client.promptContinuesAtCursor(.{ .buffer = &buffer, .cursor = .{ .visible = false, .x = end_x, .y = 0 } }));

    writePiCursor(&buffer, end_x, 0);
    try std.testing.expect(client.promptContinuesAtCursor(.{ .buffer = &buffer, .cursor = .{ .visible = false, .x = 0, .y = 0 } }));
}

const pi_uuid = "3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b";
const pi_second_uuid = "0a1b2c3d-4e5f-4a6b-8c7d-8e9f0a1b2c3d";
const pi_path = "/var/folders/8x/abc/T/pi-clipboard-" ++ pi_uuid ++ ".png";
const pi_second_path = "/var/folders/8x/abc/T/pi-clipboard-" ++ pi_second_uuid ++ ".png";

fn adoptPiCapture(store: *delivery.Store, sequence: u64, target: data.AttachmentTarget) !void {
    const capture = try testCapture(std.testing.allocator, testRequest(sequence, target), "pi");
    capture.request.marker_policy = .pasted_path;
    try store.adopt(capture);
}

fn writePiCursor(buffer: *core.Buffer, x: u16, y: u16) void {
    buffer.setCell(.{ .x = x, .y = y }, .{ .text = " ", .width = 1, .style = .{ .flags = .{ .inverse = true } } });
}

test "Pi previews pair with pasted paths and are closed by deleting the whole path" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    try adoptPiCapture(&store, 1, target);
    try adoptPiCapture(&store, 2, target);
    var buffer = try core.Buffer.init(std.testing.allocator, 200, 2);
    defer buffer.deinit();
    const prompt = "see " ++ pi_path ++ " and " ++ pi_second_path;
    const cursor_x = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = prompt, .style = .{} });
    writePiCursor(&buffer, cursor_x, 0);
    const hidden: core.Cursor = .{ .visible = false, .x = 0, .y = 0 };

    try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, .{ .buffer = &buffer, .cursor = hidden }));

    const removal = store.planMarkerRemoval(@enumFromInt(1), .{ .buffer = &buffer, .cursor = hidden }).?;
    try std.testing.expect(removal.direction == .left);
    try std.testing.expectEqual(@as(u8, " and ".len + pi_second_path.len), removal.steps);
    try std.testing.expect(removal.deletion == .backward);
    try std.testing.expectEqual(@as(u8, pi_path.len), removal.deletions);

    const second = store.planMarkerRemoval(@enumFromInt(2), .{ .buffer = &buffer, .cursor = hidden }).?;
    try std.testing.expectEqual(@as(u8, 0), second.steps);
    try std.testing.expectEqual(@as(u8, pi_second_path.len), second.deletions);

    try std.testing.expectEqual(
        @as(data.AttachmentId, @enumFromInt(2)),
        store.idAtMarkerDeletion(.{ .buffer = &buffer, .cursor = hidden }, .backward).?,
    );
    try std.testing.expect(store.idAtMarkerDeletion(.{ .buffer = &buffer, .cursor = hidden }, .forward) == null);
    try std.testing.expectEqual(
        @as(data.AttachmentId, @enumFromInt(1)),
        store.idAtMarkerDeletion(.{ .buffer = &buffer, .cursor = .{ .visible = true, .x = 4, .y = 0 } }, .forward).?,
    );
}

test "a Pi path removed by any editor command retires its preview within the watched frames" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    try adoptPiCapture(&store, 1, target);
    var buffer = try core.Buffer.init(std.testing.allocator, 40, 4);
    defer buffer.deinit();
    var x: u16 = 0;
    var y: u16 = 0;
    for (pi_path) |byte| {
        if (x == buffer.w - 1) {
            x = 0;
            y += 1;
        }
        buffer.setCell(.{ .x = x, .y = y }, .{ .text = &.{byte}, .width = 1, .style = .{} });
        x += 1;
    }
    const hidden: core.Cursor = .{ .visible = false, .x = 0, .y = 0 };
    const screen: client.MarkerScreen = .{ .buffer = &buffer, .cursor = hidden };

    try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, screen));
    store.expectMarkerDeletion(target);
    try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, screen));
    try std.testing.expect(store.marker_deletion_pending != null);

    buffer.clear(.{});
    try std.testing.expectEqual(@as(u8, 1), store.reconcileMarkers(target, screen));
    try std.testing.expectEqual(@as(u8, 0), store.snapshot().len);
    try std.testing.expect(store.marker_deletion_pending == null);
}

test "a deletion watch expires after the bounded frame count" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    try adoptPiCapture(&store, 1, target);
    var buffer = try core.Buffer.init(std.testing.allocator, 120, 1);
    defer buffer.deinit();
    _ = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = pi_path, .style = .{} });
    const screen: client.MarkerScreen = .{ .buffer = &buffer, .cursor = .{ .visible = false, .x = 0, .y = 0 } };
    _ = store.reconcileMarkers(target, screen);

    store.expectMarkerDeletion(target);
    for (0..data.attachment_types.deletion_watch_frames) |_| {
        try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, screen));
    }

    try std.testing.expect(store.marker_deletion_pending == null);
    buffer.clear(.{});
    try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, screen));
    try std.testing.expectEqual(@as(u8, 1), store.snapshot().len);
}

test "deleting a Pi path whose capture is still in flight is reported" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    var buffer = try core.Buffer.init(std.testing.allocator, 120, 1);
    defer buffer.deinit();
    const cursor_x = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = pi_path, .style = .{} });
    writePiCursor(&buffer, cursor_x, 0);
    const screen: client.MarkerScreen = .{ .buffer = &buffer, .cursor = .{ .visible = false, .x = 0, .y = 0 } };

    try std.testing.expect(store.pendingMarkerAtDeletion(screen, .{ .deletion = .backward, .policy = .pasted_path }));
    try std.testing.expect(!store.pendingMarkerAtDeletion(screen, .{ .deletion = .forward, .policy = .pasted_path }));
    try std.testing.expect(!store.pendingMarkerAtDeletion(screen, .{ .deletion = .backward }));
}

test "submitted prompt retires only previews owned by its target" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const submitted: data.AttachmentTarget = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    const other: data.AttachmentTarget = .{ .pane_id = @enumFromInt(9), .pane_generation = 2 };
    _ = store.setTarget(submitted);
    try store.adopt(try testCapture(std.testing.allocator, testRequest(1, submitted), "first"));
    try store.adopt(try testCapture(std.testing.allocator, testRequest(2, submitted), "second"));
    try store.adopt(try testCapture(std.testing.allocator, testRequest(3, other), "other"));

    try std.testing.expectEqual(@as(u8, 2), store.removeVisible(submitted));
    try std.testing.expectEqual(@as(u8, 0), store.snapshot().len);
    try std.testing.expect(store.setTarget(other).layout_changed);
    try std.testing.expectEqual(@as(u8, 1), store.snapshot().len);
}

test "preview store emits PNG and client-owned z-index placements" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt(8), .pane_generation = 2 };
    _ = store.setTarget(target);
    try store.adopt(try testCapture(
        std.testing.allocator,
        testRequest(1, target),
        "encoded png",
    ));
    _ = delivery.configure(&store, .{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var plan: client.Plan = .{ .thumbnail_count = 1 };
    plan.thumbnails[0] = .{
        .id = @enumFromInt(1),
        .area = .{ .x = 2, .y = 3, .w = 10, .h = 4 },
    };
    delivery.prepare(&store, plan);

    var output: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    _ = try delivery.write(&store, &writer);
    const bytes = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "a=t,f=100,t=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "z=1500") != null);
    try std.testing.expect(!delivery.damaged(&store));
}

test "dismissal defers private buffer wiping to the media path" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt(9), .pane_generation = 2 };
    _ = store.setTarget(target);
    try store.adopt(try testCapture(
        std.testing.allocator,
        testRequest(1, target),
        "private png",
    ));
    try std.testing.expect(store.remove(@enumFromInt(1)));
    try std.testing.expect(store.cleanupPending());
    try std.testing.expectEqual(@as(usize, 11), store.retainedBytes());
    try std.testing.expectEqual(@as(u8, 0), store.snapshot().len);
    store.reapRetired();
    try std.testing.expect(!store.cleanupPending());
    try std.testing.expectEqual(@as(usize, 0), store.retainedBytes());
}

test "cancelling a dismissed PNG transfer owns the graphics stream until abort" {
    var store = delivery.Store.init(std.testing.allocator);
    defer store.deinit();
    const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt(10), .pane_generation = 2 };
    _ = store.setTarget(target);
    const large = try std.testing.allocator.alloc(u8, kitty_codec.transmission_budget_per_frame);
    defer std.testing.allocator.free(large);
    @memset(large, 0xaa);
    try store.adopt(try testCapture(
        std.testing.allocator,
        testRequest(1, target),
        large,
    ));
    _ = delivery.configure(&store, .{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var plan: client.Plan = .{ .thumbnail_count = 1 };
    plan.thumbnails[0] = .{
        .id = @enumFromInt(1),
        .area = .{ .w = 10, .h = 4 },
    };
    delivery.prepare(&store, plan);
    var discarded: std.Io.Writer.Discarding = .init(&.{});
    _ = try delivery.write(&store, &discarded.writer);
    try std.testing.expect(delivery.transferInProgress(&store));
    try std.testing.expect(store.remove(@enumFromInt(1)));
    try std.testing.expect(delivery.transferInProgress(&store));
    store.reapRetired();

    var output: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    _ = try delivery.write(&store, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b_Gm=0;") != null);
    try std.testing.expect(!delivery.transferInProgress(&store));
}
