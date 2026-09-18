const std = @import("std");
const core = @import("telar-core");
const Fixture = @import("ConversationFixture.zig");
const Text = @import("../widgets/MessageText.zig");
const TextFlow = @import("../widgets/MessageTextFlow.zig");
const ThreadFlow = @import("../widgets/ThreadFlow.zig");
const Rect = @import("../render/Rect.zig");

test "conversation text wraps measured sans glyphs and shares paint geometry" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    const area: Rect = .{ .x = 10, .y = 12, .width = 80, .height = 500 };
    var text: Text = .{ .bounds = area, .viewport = area, .text = "iiiiiiiiiiiiiiii", .markdown = false };
    const narrow_glyphs = try text.measure(&canvas);
    text.text = "WWWWWWWWWWWWWWWW";
    const wide_glyphs = try text.measure(&canvas);
    try std.testing.expect(wide_glyphs > narrow_glyphs);
    try std.testing.expectEqual(@as(usize, 0), fixture.quads.items().len);
    text.text = "## Result\nA **bold** response with `code`.\n\n- One item\n> Note\n```zig\nconst done = true;\n```";
    const expected = try text.measure(&canvas);
    try text.draw(&canvas);
    try std.testing.expectEqual(expected, try text.measure(&canvas));
    for (fixture.quads.items()) |quad| {
        try std.testing.expect(quad.x >= area.x and quad.y >= area.y);
        try std.testing.expect(quad.x + quad.width <= area.x + area.width + 0.01);
        try std.testing.expect(quad.y + quad.height <= @min(area.y + expected, area.y + area.height) + 0.01);
    }

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.atlas.allocator = failing.allocator();
    fixture.quads.allocator = failing.allocator();
    defer fixture.atlas.allocator = std.testing.allocator;
    defer fixture.quads.allocator = std.testing.allocator;
    for (0..3) |_| {
        fixture.quads.clear();
        _ = try text.measure(&canvas);
        try text.draw(&canvas);
    }

    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "48 KiB unbroken text has bounded shaping spans and linear measured work" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    try fixture.atlas.prepareEditor();
    const storage = try std.testing.allocator.alloc(u8, 48 * 1024);
    defer std.testing.allocator.free(storage);
    const area: Rect = .{ .x = 0, .y = 0, .width = 160, .height = 200 };
    for ([_][]const u8{ "w", "界", "e\u{301}" }) |cluster| {
        const length = storage.len / cluster.len * cluster.len;
        var index: usize = 0;
        while (index < length) : (index += cluster.len) {
            @memcpy(storage[index..][0..cluster.len], cluster);
        }

        var flow: TextFlow = .{ .canvas = &canvas, .bounds = area, .viewport = area, .row = 25, .paint = false };
        try flow.append(.{ .text = storage[0..length], .face = .sans, .size = .body });
        try std.testing.expectEqual(length, flow.laid_out_bytes);
        try std.testing.expect(flow.max_measured_span <= TextFlow.chunk_bytes);
        try std.testing.expect(flow.measured_bytes <= length * 64);
        try std.testing.expect(flow.height() > area.height);
        var warm: TextFlow = .{ .canvas = &canvas, .bounds = area, .viewport = area, .row = 25, .paint = false };
        const start = std.Io.Clock.awake.now(std.testing.io);
        try warm.append(.{ .text = storage[0..length], .face = .sans, .size = .body });
        const elapsed = start.durationTo(std.Io.Clock.awake.now(std.testing.io));
        std.debug.print("\nconversation 48KiB {s}: {d}us; measured={d} bytes; span={d}\n", .{ cluster, elapsed.toMicroseconds(), warm.measured_bytes, warm.max_measured_span });
    }
}

test "warm transcript frame measures and paints a full 48 KiB retained response" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var canvas = fixture.canvas();
    const snapshot = try std.testing.allocator.create(core.AgentThreadSnapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{ .pane_id = @enumFromInt(1), .pane_generation = 1, .status = .working };
    snapshot.item_storage[0] = .{ .identity = 1, .role = .assistant, .status = .running, .text_len = snapshot.text_storage.len };
    snapshot.item_count = 1;
    snapshot.text_len = snapshot.text_storage.len;
    for ([_][]const u8{ "w", "界" }) |cluster| {
        snapshot.revision += 1;
        var index: usize = 0;
        while (index < snapshot.text_storage.len) : (index += cluster.len) {
            @memcpy(snapshot.text_storage[index..][0..cluster.len], cluster);
        }

        for ([_]f32{ 160, 640 }) |width| {
            const transcript: @import("../widgets/ThreadTranscript.zig") = .{ .bounds = .{ .x = 0, .y = 32, .width = width, .height = 400 }, .thread = .{ .pane_id = snapshot.pane_id, .agent = null, .composer = "", .kind = .agent, .transcript = snapshot } };
            try transcript.draw(&canvas);
            try std.testing.expect(fixture.state.?.message_layout != null);
            fixture.quads.clear();
            fixture.clock.begin(0);
            const start = std.Io.Clock.awake.now(std.testing.io);
            try transcript.draw(&canvas);
            try (@import("../widgets/ActivityText.zig"){ .bounds = .{ .x = 0, .y = 0, .width = width, .height = 32 }, .label = .{ .text = "Writing response", .face = .sans, .size = .small }, .active = true }).draw(&canvas);
            const elapsed = start.durationTo(std.Io.Clock.awake.now(std.testing.io));
            std.debug.print("\nconversation frame48KiB {s} width{d}: {d}us; quads={d}; layoutcache={d} bytes\n", .{ cluster, width, elapsed.toMicroseconds(), fixture.quads.items().len, @sizeOf(@import("../widgets/MessageLayoutCache.zig")) });
            try std.testing.expect(fixture.clock.deadline_ns != null);
            try std.testing.expect(fixture.quads.items().len < 4096);
            fixture.quads.clear();
        }
    }
}

test "long message plans match uncached painting and invalidate all source and geometry changes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var canvas = fixture.canvas();
    var storage: [4096]u8 = @splat('w');
    const area: Rect = .{ .x = 5, .y = 12, .width = 240, .height = 240 };
    var text: Text = .{ .bounds = area, .viewport = area, .text = &storage, .markdown = false, .owner = .{ .pane_id = @enumFromInt(1), .attachment_generation = 1, .pane_generation = 1, .snapshot_revision = 1, .item_identity = 1, .section = .body, .source_offset = 0 } };
    _ = try text.measure(&canvas);
    try text.draw(&canvas);
    const cache = fixture.state.?.message_layout.?;
    const next_plan = cache.next_plan;
    fixture.quads.clear();
    try text.draw(&canvas);
    try std.testing.expectEqual(next_plan, cache.next_plan);
    const cached = try std.testing.allocator.dupe(@import("../render/Quad.zig").Quad, fixture.quads.items());
    defer std.testing.allocator.free(cached);
    canvas.widgets = null;
    fixture.quads.clear();
    try text.draw(&canvas);
    try std.testing.expectEqualSlices(@import("../render/Quad.zig").Quad, cached, fixture.quads.items());
    canvas.widgets = fixture.state;
    for (0..9) |change| {
        switch (change) {
            0 => storage[0] = 'i',
            1 => text.owner.?.snapshot_revision += 1,
            2 => text.owner.?.attachment_generation += 1,
            3 => text.owner.?.pane_id = @enumFromInt(2),
            4 => text.bounds.y -= 25,
            5 => text.bounds.width -= 17,
            6 => canvas.chrome.body += 1,
            7 => fixture.atlas.fonts.revision += 1,
            8 => fixture.atlas.fonts.identity += 1,
            else => unreachable,
        }

        const before = cache.next_plan;
        fixture.quads.clear();
        try text.draw(&canvas);
        try std.testing.expect(cache.next_plan != before);
        const warm = cache.next_plan;
        fixture.quads.clear();
        try text.draw(&canvas);
        try std.testing.expectEqual(warm, cache.next_plan);
    }

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.atlas.allocator = failing.allocator();
    fixture.quads.allocator = failing.allocator();
    defer fixture.atlas.allocator = std.testing.allocator;
    defer fixture.quads.allocator = std.testing.allocator;
    fixture.quads.clear();
    try text.draw(&canvas);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "paint plan overflow falls back without dropping any visible message fragments" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var canvas = fixture.canvas();
    const source = "word " ** 2049;
    const area: Rect = .{ .x = 0, .y = 0, .width = 240, .height = 100000 };
    const text: Text = .{ .bounds = area, .viewport = area, .text = source, .markdown = false, .owner = .{ .pane_id = @enumFromInt(1), .attachment_generation = 1, .pane_generation = 1, .snapshot_revision = 1, .item_identity = 1, .section = .body, .source_offset = 0 } };
    try text.draw(&canvas);
    const count = fixture.quads.items().len;
    try std.testing.expect(count > 2048);
    const cache = fixture.state.?.message_layout.?;
    try std.testing.expect(cache.plans[0].overflow and !cache.plans[0].valid);
    canvas.widgets = null;
    fixture.quads.clear();
    try text.draw(&canvas);
    try std.testing.expectEqual(count, fixture.quads.items().len);
}

test "offscreen running activity parks while visible activity requests the next frame" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    const snapshot = try std.testing.allocator.create(core.AgentThreadSnapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{ .pane_id = @enumFromInt(1), .pane_generation = 1, .status = .working };
    const response = "A completed response.\n" ** 40;
    @memcpy(snapshot.text_storage[0..response.len], response);
    snapshot.text_len = response.len;
    snapshot.item_storage[0] = .{ .identity = 1, .role = .assistant, .kind = .reasoning, .status = .running };
    snapshot.item_storage[1] = .{ .identity = 2, .role = .assistant, .status = .completed, .text_len = response.len, .complete = true };
    snapshot.item_count = 2;
    var flow: ThreadFlow = .{ .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 150 }, .thread = .{ .pane_id = snapshot.pane_id, .agent = null, .composer = "", .kind = .agent, .transcript = snapshot } };
    try flow.resolve(&canvas);
    fixture.clock.begin(0);
    try flow.draw(&canvas);
    try std.testing.expectEqual(@as(?u64, null), fixture.clock.deadline_ns);
    flow.thread.transcript_scroll = flow.scroll_limit;
    try flow.resolve(&canvas);
    fixture.clock.begin(1);
    fixture.quads.clear();
    try flow.draw(&canvas);
    try std.testing.expect(fixture.clock.deadline_ns != null);
    snapshot.item_storage[0].status = .completed;
    try flow.resolve(&canvas);
    fixture.clock.begin(2);
    fixture.quads.clear();
    try flow.draw(&canvas);
    try std.testing.expectEqual(@as(?u64, null), fixture.clock.deadline_ns);
}

test "subagent status updates preserve fixed identity card height and parent indent" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var canvas = fixture.canvas();
    const snapshot = try std.testing.allocator.create(core.AgentThreadSnapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 };
    snapshot.item_storage[0] = .{ .identity = 5, .role = .tool, .kind = .dispatch, .status = .completed };
    snapshot.item_storage[1] = .{ .identity = 7, .parent_identity = 5, .role = .tool, .kind = .subagent, .status = .running };
    snapshot.item_count = 2;
    var flow: ThreadFlow = .{ .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 500 }, .thread = .{ .pane_id = snapshot.pane_id, .agent = null, .composer = "", .kind = .agent, .transcript = snapshot } };
    try flow.resolve(&canvas);
    fixture.state.?.thread_expansions.toggle(flow.rows[0].control());
    try flow.resolve(&canvas);
    const geometry = flow.rows[2].bounds;
    try std.testing.expectEqual(@as(u8, 1), flow.rows[2].depth);
    try std.testing.expect(geometry.x > flow.rows[1].bounds.x);
    for ([_]core.agent_thread.ItemStatus{ .idle, .completed, .failed, .interrupted, .closed }) |status| {
        snapshot.item_storage[1].status = status;
        try flow.resolve(&canvas);
        try std.testing.expectEqualDeep(geometry, flow.rows[2].bounds);
        try std.testing.expectEqual(@as(u64, 7), flow.rows[2].item.identity);
    }
}
