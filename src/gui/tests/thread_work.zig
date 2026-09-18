const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ConversationFixture.zig");
const Flow = @import("../widgets/ThreadFlow.zig");

fn snapshot() !*core.AgentThreadSnapshot {
    const value = try std.testing.allocator.create(core.AgentThreadSnapshot);
    value.* = .{ .pane_id = @enumFromInt(1), .pane_generation = 7, .revision = 1, .status = .ready };
    const items = [_]core.AgentThreadItem{
        .{ .identity = 1, .role = .user },
        .{ .identity = 2, .role = .assistant, .phase = .commentary },
        .{ .identity = 3, .role = .assistant, .kind = .reasoning },
        .{ .identity = 4, .role = .tool, .kind = .command },
        .{ .identity = 5, .role = .tool, .kind = .dispatch },
        .{ .identity = 6, .role = .tool, .kind = .subagent, .parent_identity = 5 },
        .{ .identity = 7, .role = .assistant, .phase = .final_answer },
    };
    const text = "Readable content\n";
    @memcpy(value.text_storage[0..text.len], text);
    value.text_len = text.len;
    @memcpy(value.metadata_storage[0..6], "turn-1");
    value.metadata_len = 6;
    value.item_count = items.len;
    for (items, 0..) |item, index| {
        value.item_storage[index] = item;
        value.item_storage[index].source_turn_len = 6;
        value.item_storage[index].source_offset = value.metadata_len;
        value.item_storage[index].source_len = 1;
        value.metadata_storage[value.metadata_len] = 'a' + @as(u8, @intCast(index));
        value.metadata_len += 1;
        value.item_storage[index].text_len = text.len;
        value.item_storage[index].complete = true;
        value.item_storage[index].status = .completed;
    }

    return value;
}

fn flowFor(value: *const core.AgentThreadSnapshot) Flow {
    return .{ .bounds = .{ .x = 0, .y = 0, .width = 500, .height = 900 }, .thread = .{ .pane_id = value.pane_id, .attachment_generation = 3, .agent = null, .composer = "", .kind = .agent, .transcript = value } };
}

test "work folds commentary reasoning commands and children while keeping prompt and final response" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var canvas = fixture.canvas();
    const value = try snapshot();
    defer std.testing.allocator.destroy(value);
    var flow = flowFor(value);
    try flow.resolve(&canvas);
    try flow.draw(&canvas);
    try std.testing.expectEqual(@as(usize, 3), flow.len);
    try std.testing.expectEqual(@as(u64, 1), flow.rows[0].item.identity);
    try std.testing.expectEqual(@as(u16, 5), flow.rows[1].work_count);
    try std.testing.expectEqual(@as(u64, 7), flow.rows[2].item.identity);
    try std.testing.expectEqual(@as(u16, 2), fixture.state.?.thread_text.?.maps.preparing().row_count);
    const collapsed_height = flow.height;
    const header = flow.rows[1].control();
    fixture.state.?.thread_expansions.toggle(header);
    try flow.resolve(&canvas);
    try std.testing.expectEqual(@as(usize, 8), flow.len);
    try std.testing.expect(flow.height > collapsed_height);
    try std.testing.expect(flow.rows[1].expanded);
    try std.testing.expect(!flow.rows[2].expanded);
    try std.testing.expect(!header.sameItem(flow.rows[2].control()));
    for (flow.rows[2..7], 2..) |view, identity| {
        try std.testing.expectEqual(@as(u64, identity), view.item.identity);
    }

    fixture.state.?.thread_expansions.toggle(header);
    try flow.resolve(&canvas);
    try std.testing.expectEqual(collapsed_height, flow.height);
    try std.testing.expectEqual(@as(u8, 7), value.item_count);
}

test "work disclosure survives streaming and completion but a new turn starts folded" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var canvas = fixture.canvas();
    const value = try snapshot();
    defer std.testing.allocator.destroy(value);
    value.status = .working;
    value.item_count = 4;
    value.item_storage[3].status = .running;
    var flow = flowFor(value);
    try flow.resolve(&canvas);
    const header = flow.rows[1].control();
    fixture.state.?.thread_expansions.toggle(header);
    value.revision += 1;
    value.item_count = 7;
    try flow.resolve(&canvas);
    try std.testing.expect(flow.rows[1].expanded and flow.rows[1].work_active);
    value.status = .ready;
    value.item_storage[3].status = .completed;
    try flow.resolve(&canvas);
    try std.testing.expect(flow.rows[1].expanded and !flow.rows[1].work_active);

    const turn_offset = value.metadata_len;
    @memcpy(value.metadata_storage[turn_offset..][0..6], "turn-2");
    value.metadata_len += 6;
    value.item_storage[7] = .{ .identity = 8, .role = .user, .source_turn_offset = turn_offset, .source_turn_len = 6 };
    value.item_storage[8] = .{ .identity = 9, .role = .tool, .kind = .command, .source_turn_offset = turn_offset, .source_turn_len = 6 };
    value.item_count = 9;
    try flow.resolve(&canvas);
    try std.testing.expectEqual(@as(usize, 10), flow.len);
    try std.testing.expect(flow.rows[1].expanded);
    try std.testing.expectEqual(@as(u16, 1), flow.rows[9].work_count);
    try std.testing.expect(!flow.rows[9].expanded);
    flow.thread.attachment_generation += 1;
    try flow.resolve(&canvas);
    try std.testing.expect(!flow.rows[1].expanded);
}

test "work spans history page seams and keeps disclosure when its first retained item changes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var canvas = fixture.canvas();
    const value = try snapshot();
    defer std.testing.allocator.destroy(value);
    const window = try std.testing.allocator.create(client.AgentHistoryWindow);
    defer std.testing.allocator.destroy(window);
    window.start(value, 1);
    window.pages[1] = window.pages[0];
    window.count = 2;
    window.pages[0].snapshot.item_count = 4;
    const newer = &window.pages[1].snapshot;
    std.mem.copyForwards(core.AgentThreadItem, newer.item_storage[0..4], newer.item_storage[3..7]);
    newer.item_count = 4;
    var flow = flowFor(value);
    flow.thread.history = window;
    try flow.resolve(&canvas);
    try std.testing.expectEqual(@as(usize, 3), flow.len);
    try std.testing.expectEqual(@as(u16, 5), flow.rows[1].work_count);
    const header = flow.rows[1].control();
    fixture.state.?.thread_expansions.toggle(header);
    window.pages[0] = window.pages[1];
    window.count = 1;
    try flow.resolve(&canvas);
    try std.testing.expectEqual(@as(u16, 3), flow.rows[0].work_count);
    try std.testing.expect(flow.rows[0].expanded);
    try std.testing.expect(header.sameItem(flow.rows[0].control()));
}

test "system notices and unclassified public answers are never hidden as work" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    const value = try snapshot();
    defer std.testing.allocator.destroy(value);
    value.item_storage[1].phase = .unknown;
    value.item_storage[6] = .{ .identity = 7, .role = .system, .kind = .system, .text_len = value.text_len };
    var flow = flowFor(value);
    try flow.resolve(&canvas);
    try std.testing.expectEqual(@as(usize, 4), flow.len);
    try std.testing.expectEqual(@as(u64, 2), flow.rows[1].item.identity);
    try std.testing.expectEqual(@as(u16, 4), flow.rows[2].work_count);
    try std.testing.expectEqual(@as(u64, 7), flow.rows[3].item.identity);
}

test "hidden work growth and retained child expansions consume no scroll extent" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var canvas = fixture.canvas();
    const value = try snapshot();
    defer std.testing.allocator.destroy(value);
    var flow = flowFor(value);
    flow.bounds.height = 120;
    try flow.resolve(&canvas);
    const height = flow.height;
    const limit = flow.scroll_limit;
    const header = flow.rows[1].control();
    fixture.state.?.thread_expansions.toggle(header);
    try flow.resolve(&canvas);
    fixture.state.?.thread_expansions.toggle(flow.rows[4].control());
    try flow.resolve(&canvas);
    try std.testing.expect(flow.height > height);
    fixture.state.?.thread_expansions.toggle(header);

    const output = "Hidden command output\n" ** 500;
    const offset = value.text_len;
    @memcpy(value.text_storage[offset..][0..output.len], output);
    value.text_len += output.len;
    value.item_storage[3].text_offset = offset;
    value.item_storage[3].text_len = output.len;
    value.revision += 1;
    try flow.resolve(&canvas);
    try std.testing.expectEqual(height, flow.height);
    try std.testing.expectEqual(limit, flow.scroll_limit);
    flow.thread.transcript_scroll = limit;
    try flow.resolve(&canvas);
    try std.testing.expectEqual(@as(f32, 12), flow.rows[0].bounds.y);
}
