const std = @import("std");
const core = @import("telar-core");
const Fixture = @import("ConversationFixture.zig");
const Geometry = @import("../widgets/interaction/ThreadTextGeometry.zig");
const Store = @import("../widgets/interaction/ThreadTextStore.zig");
const Run = @import("../widgets/interaction/ThreadTextRun.zig");
const View = @import("../widgets/ThreadItemView.zig");
const Rect = @import("../render/Rect.zig");

fn snapshot() core.AgentThreadSnapshot {
    var value: core.AgentThreadSnapshot = .{ .pane_id = @enumFromInt(1), .pane_generation = 3, .revision = 5 };
    value.item_storage[0] = .{ .identity = 7, .role = .assistant, .text_offset = 32, .text_len = 128 };
    value.item_count = 1;
    return value;
}

fn view(value: *const core.AgentThreadSnapshot) View {
    const area: Rect = .{ .x = 10, .y = 20, .width = 500, .height = 300 };
    return .{ .thread = .{ .pane_id = value.pane_id, .agent = null, .composer = "", .attachment_generation = 11, .kind = .agent, .transcript = value }, .item = &value.item_storage[0], .bounds = area, .viewport = area };
}

fn run(value: View, text: []const u8) Run {
    return .{ .owner = value.source(.body), .offset = value.item.text_offset, .text = text, .bounds = value.bounds, .viewport = value.viewport, .advance = @as(f32, @floatFromInt(text.len * 9)), .face = .mono, .pixel_height = 15 };
}

fn containsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |array| containsPointer(array.child),
        .optional => |optional| containsPointer(optional.child),
        .@"struct" => |structure| found: {
            inline for (structure.fields) |field| {
                if (containsPointer(field.type)) {
                    break :found true;
                }
            }

            break :found false;
        },
        else => false,
    };
}

test "thread text geometry owns source coordinates within a fixed lazy store" {
    try std.testing.expect(!containsPointer(Geometry));
    try std.testing.expect(@sizeOf(Store) < 2 * 1024 * 1024);
    std.debug.print("\nthread selection geometry={d} bytes; double-buffered store={d} bytes\n", .{ @sizeOf(Geometry), @sizeOf(Store) });
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    try std.testing.expect(fixture.state.?.thread_text == null);
    const store = try fixture.state.?.threadText(std.testing.allocator);
    var value = snapshot();
    var canvas = fixture.canvas();
    const geometry = store.maps.begin();
    geometry.addRow(view(&value), 2);
    var source = [_]u8{ 'e', 0xcc, 0x81, 'x' };
    const fragment = (try geometry.append(&canvas, run(view(&value), &source))).?;
    @memset(&source, 'z');
    value.item_storage[0].identity = 99;
    value.revision = 100;
    const caret = geometry.position(fragment, 1);
    try std.testing.expectEqual(@as(u32, 35), caret.offset);
    try std.testing.expectEqual(@as(u64, 7), caret.owner.item_identity);
    try std.testing.expectEqual(@as(u64, 5), caret.owner.snapshot_revision);
    try std.testing.expectEqual(@as(u64, 11), caret.owner.attachment_generation);
    try std.testing.expectEqual(@as(u16, 2), caret.order);
}

test "thread text mono carets follow graphemes and wide cells without splitting combining text" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const geometry = (try fixture.state.?.threadText(std.testing.allocator)).maps.begin();
    var value = snapshot();
    var canvas = fixture.canvas();
    geometry.addRow(view(&value), 0);
    const fragment = (try geometry.append(&canvas, run(view(&value), "e\u{301}界👩‍💻x"))).?;
    const expected_offsets = [_]u16{ 0, 3, 6, 17, 18 };
    const expected_x = [_]f32{ 0, 9, 27, 45, 54 };
    try std.testing.expectEqual(expected_offsets.len, fragment.caret_count);
    for (geometry.carets[fragment.caret_start..][0..fragment.caret_count], expected_offsets, expected_x) |caret, offset, x| {
        try std.testing.expectEqual(offset, caret.offset);
        try std.testing.expectEqual(x, caret.x);
    }

    const hit = geometry.hit(.{ .pane_id = value.pane_id, .point = .{ 20, 25 } }).?;
    try std.testing.expectEqual(@as(u32, 35), hit.offset);
}

test "thread text sans carets match whole shaped runs including ligature interiors without warm allocations" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const geometry = (try fixture.state.?.threadText(std.testing.allocator)).maps.begin();
    var value = snapshot();
    var canvas = fixture.canvas();
    try fixture.atlas.prepareEditor();
    const source = "office e\u{301} WWW";
    var positions: [source.len + 1]u32 = undefined;
    try fixture.atlas.caretPositions(.{ .text = source, .x = 0, .y = 0, .color = .white, .pixel_height = 15, .face = .sans }, &positions);
    var input = run(view(&value), source);
    input.face = .sans;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.atlas.allocator = failing.allocator();
    defer fixture.atlas.allocator = std.testing.allocator;
    geometry.addRow(view(&value), 0);
    const fragment = (try geometry.append(&canvas, input)).?;
    for (geometry.carets[fragment.caret_start..][0..fragment.caret_count]) |caret| {
        try std.testing.expectEqual(@as(f32, @floatFromInt(positions[caret.offset])), caret.x);
    }

    try std.testing.expect(positions[2] > positions[1] and positions[2] < positions[4]);
    try std.testing.expect(positions[source.len] - positions[source.len - 1] > positions[4] - positions[3]);
    const middle = geometry.hit(.{ .pane_id = value.pane_id, .point = .{ input.bounds.x + @as(f64, @floatFromInt(positions[2])), input.bounds.y + 5 } }).?;
    try std.testing.expectEqual(input.offset + 2, middle.offset);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "thread text hit testing excludes clipped carets invisible lines and other panes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const geometry = (try fixture.state.?.threadText(std.testing.allocator)).maps.begin();
    var value = snapshot();
    var canvas = fixture.canvas();
    geometry.addRow(view(&value), 0);
    var input = run(view(&value), "abcd");
    input.bounds.height = 22;
    input.viewport = .{ .x = 20, .y = 25, .width = 17, .height = 8 };
    _ = try geometry.append(&canvas, input);
    const left = geometry.hit(.{ .pane_id = value.pane_id, .point = .{ 19, 26 } }).?;
    try std.testing.expectEqual(input.offset + 2, left.offset);
    const right = geometry.hit(.{ .pane_id = value.pane_id, .point = .{ 1000, 26 } }).?;
    try std.testing.expectEqual(input.offset + 3, right.offset);
    try std.testing.expect(geometry.hit(.{ .pane_id = @enumFromInt(99), .point = .{ 28, 26 } }) == null);
    input.bounds.y = 200;
    input.offset += 50;
    _ = try geometry.append(&canvas, input);
    try std.testing.expectEqual(left.offset, geometry.hit(.{ .pane_id = value.pane_id, .point = .{ 19, 210 } }).?.offset);
}

test "thread text carets and highlight stay inside the glyph fragment clip" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const state = fixture.state.?;
    const geometry = (try state.threadText(std.testing.allocator)).maps.begin();
    var value = snapshot();
    var canvas = fixture.canvas();
    geometry.addRow(view(&value), 0);
    var input = run(view(&value), "abcd");
    input.bounds.width = 10;
    input.bounds.height = 22;
    const fragment = (try geometry.append(&canvas, input)).?;
    const hit = geometry.hit(.{ .pane_id = value.pane_id, .point = .{ 100, 25 } }).?;
    try std.testing.expectEqual(input.offset + 1, hit.offset);
    state.thread_selection = .{ .owner = .{ .pane_id = value.pane_id, .attachment_generation = input.owner.attachment_generation }, .anchor = geometry.position(fragment, 0), .head = geometry.position(fragment, 4) };
    try (@import("../widgets/ThreadTextPaint.zig"){ .geometry = geometry, .fragment = fragment }).draw(&canvas);
    try std.testing.expect(fixture.quads.items().len > 0);
    for (fixture.quads.items()) |quad| {
        try std.testing.expect(quad.x >= input.bounds.x and quad.y >= input.bounds.y);
        try std.testing.expect(quad.x + quad.width <= input.bounds.x + input.bounds.width);
        try std.testing.expect(quad.y + quad.height <= input.bounds.y + input.bounds.height);
    }
}

test "thread text failed frame delivery retains old ownership until a successful replacement" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const state = fixture.state.?;
    const store = try state.threadText(std.testing.allocator);
    var value = snapshot();
    var canvas = fixture.canvas();
    state.begin(false);
    store.maps.preparing().addRow(view(&value), 0);
    _ = try store.maps.preparing().append(&canvas, run(view(&value), "first"));
    state.seal();
    state.present(true);
    const hit: @import("../widgets/interaction/ThreadTextHit.zig") = .{ .pane_id = value.pane_id, .point = .{ 10, 25 } };
    const initial = store.maps.presented().hit(hit).?;
    value.revision += 1;
    value.item_storage[0].identity += 1;
    state.begin(false);
    store.maps.preparing().addRow(view(&value), 0);
    _ = try store.maps.preparing().append(&canvas, run(view(&value), "second"));
    state.seal();
    try std.testing.expectEqualDeep(initial, store.maps.presented().hit(hit).?);
    state.present(false);
    try std.testing.expectEqualDeep(initial, store.maps.presented().hit(hit).?);
    state.begin(false);
    state.seal();
    state.present(true);
    try std.testing.expect(store.maps.presented().hit(hit) == null);
}

test "thread text rejects stale ownership while metadata keeps its own source coordinates" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const geometry = (try fixture.state.?.threadText(std.testing.allocator)).maps.begin();
    var value = snapshot();
    value.item_storage[0].kind = .command;
    value.item_storage[0].role = .tool;
    value.item_storage[0].detail_offset = 200;
    value.item_storage[0].detail_len = 20;
    var canvas = fixture.canvas();
    var expanded = view(&value);
    expanded.expanded = true;
    geometry.addRow(expanded, 0);
    const input = run(view(&value), "text");
    for (0..5) |change| {
        var stale = input;
        switch (change) {
            0 => stale.owner.pane_id = @enumFromInt(2),
            1 => stale.owner.attachment_generation += 1,
            2 => stale.owner.pane_generation += 1,
            3 => stale.owner.snapshot_revision += 1,
            4 => stale.owner.item_identity += 1,
            else => unreachable,
        }

        try std.testing.expect(try geometry.append(&canvas, stale) == null);
    }

    try std.testing.expectEqual(@as(u16, 0), geometry.fragment_count);
    try std.testing.expectEqual(@as(u16, 0), geometry.caret_count);
    var metadata = input;
    metadata.owner = view(&value).source(.metadata);
    metadata.offset = 204;
    const fragment = (try geometry.append(&canvas, metadata)).?;
    const caret = geometry.position(fragment, 1);
    try std.testing.expectEqual(.metadata, caret.owner.section);
    try std.testing.expectEqual(@as(u32, 200), caret.owner.source_offset);
    try std.testing.expectEqual(@as(u32, 205), caret.offset);
}

test "thread text capacity rejects whole fragments and preserves previously admitted geometry" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const store = try fixture.state.?.threadText(std.testing.allocator);
    var value = snapshot();
    var canvas = fixture.canvas();
    var geometry = store.maps.begin();
    for (0..Geometry.max_rows + 1) |_| {
        geometry.addRow(view(&value), 0);
    }

    try std.testing.expectEqual(Geometry.max_rows, geometry.row_count);
    try std.testing.expect(geometry.saturated);
    geometry = store.maps.begin();
    geometry.addRow(view(&value), 0);
    const input = run(view(&value), "x");
    for (0..Geometry.max_fragments) |_| {
        try std.testing.expect(try geometry.append(&canvas, input) != null);
    }

    const count = geometry.caret_count;
    try std.testing.expect(try geometry.append(&canvas, input) == null);
    try std.testing.expectEqual(Geometry.max_fragments, geometry.fragment_count);
    try std.testing.expectEqual(count, geometry.caret_count);
    try std.testing.expect(geometry.saturated);
    geometry = store.maps.begin();
    geometry.addRow(view(&value), 0);
    const text = try std.testing.allocator.alloc(u8, Geometry.max_carets - 1);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    try std.testing.expect(try geometry.append(&canvas, run(view(&value), text)) != null);
    try std.testing.expect(try geometry.append(&canvas, input) == null);
    try std.testing.expectEqual(Geometry.max_carets, geometry.caret_count);
    try std.testing.expectEqual(@as(u16, 1), geometry.fragment_count);
    try std.testing.expect(geometry.saturated);
}

test "thread text oversized sans input rejects clusters split by the bounded grapheme iterator" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const geometry = (try fixture.state.?.threadText(std.testing.allocator)).maps.begin();
    var value = snapshot();
    var canvas = fixture.canvas();
    geometry.addRow(view(&value), 0);
    const combined = "e" ++ "\u{301}" ** 15;
    var iterator: core.GraphemeIterator = .{ .bytes = combined };
    try std.testing.expectEqual(combined.len, iterator.next().?.bytes.len);
    try std.testing.expect(iterator.next() == null);
    var input = run(view(&value), combined);
    input.face = .sans;
    const fragment = (try geometry.append(&canvas, input)).?;
    try std.testing.expectEqual(@as(u16, 2), fragment.caret_count);
    try std.testing.expect(geometry.carets[fragment.caret_start + 1].x > 0);
    const oversized = "e" ++ "\u{301}" ** 130;
    iterator = .{ .bytes = oversized };
    try std.testing.expect(iterator.next().?.bytes.len < oversized.len);
    try std.testing.expect(iterator.next() != null);
    for ([_][]const u8{ oversized, "x" ** 257 }) |source| {
        input.text = source;
        try std.testing.expect(try geometry.append(&canvas, input) == null);
    }

    try std.testing.expect(geometry.saturated);
    try std.testing.expectEqual(@as(u16, 1), geometry.fragment_count);
    try std.testing.expectEqual(@as(u16, 2), geometry.caret_count);
}

test "thread text row catalog preserves literal prompts and expanded activity visibility" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const geometry = (try fixture.state.?.threadText(std.testing.allocator)).maps.begin();
    var value = snapshot();
    value.item_storage[0].role = .user;
    geometry.addRow(view(&value), 0);
    try std.testing.expect(!geometry.rows[0].markdown);
    try std.testing.expectEqual(value.item_storage[0].text_len, geometry.rows[0].body_len);
    value.item_storage[0].role = .tool;
    value.item_storage[0].kind = .command;
    value.item_storage[0].detail_len = 12;
    geometry.addRow(view(&value), 1);
    try std.testing.expectEqual(@as(u32, 0), geometry.rows[1].body_len);
    try std.testing.expectEqual(@as(u32, 0), geometry.rows[1].detail_len);
    var expanded = view(&value);
    expanded.expanded = true;
    geometry.addRow(expanded, 2);
    try std.testing.expect(geometry.rows[2].code);
    try std.testing.expectEqual(value.item_storage[0].text_len, geometry.rows[2].body_len);
    try std.testing.expectEqual(@as(u32, 12), geometry.rows[2].detail_len);
}

test "thread text rendered wrapping preserves absolute source offsets and excludes hidden link destinations" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const geometry = (try fixture.state.?.threadText(std.testing.allocator)).maps.begin();
    var value = snapshot();
    var canvas = fixture.canvas();
    geometry.addRow(view(&value), 0);
    const source = "office e\u{301} WWW `mono` [link](https://hidden.test)";
    const area: Rect = .{ .x = 10, .y = 20, .width = 65, .height = 300 };
    const text: @import("../widgets/MessageText.zig") = .{ .bounds = area, .viewport = area, .text = source, .owner = view(&value).source(.body) };
    try text.draw(&canvas);
    try std.testing.expect(geometry.fragment_count > 3);
    var wrapped = false;
    for (geometry.fragments[0..geometry.fragment_count]) |fragment| {
        wrapped = wrapped or fragment.bounds.y > area.y;
        const offset = fragment.offset - value.item_storage[0].text_offset;
        const visible = source[offset..][0..fragment.len];
        try std.testing.expect(std.unicode.utf8ValidateSlice(visible));
        try std.testing.expect(std.mem.indexOf(u8, visible, "https") == null);
        for (geometry.carets[fragment.caret_start..][0..fragment.caret_count]) |caret| {
            try std.testing.expect(std.unicode.utf8ValidateSlice(visible[0..caret.offset]));
        }
    }

    try std.testing.expect(wrapped);
}
