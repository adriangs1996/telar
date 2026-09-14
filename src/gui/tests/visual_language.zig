//! Slice 1 of the GUI visual language: rounded quads, rings and the sans chrome face.
const std = @import("std");
const core = @import("telar-core");
const QuadList = @import("../render/QuadList.zig");
const Quad = @import("../render/Quad.zig").Quad;
const Id = @import("../text/font_id.zig").Id;

const Fixture = @import("CanvasFixture.zig");

test "plain fills keep the textured quad path bit for bit" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    const area: core.Rect = .{ .x = 2, .y = 3, .w = 4, .h = 2 };
    try canvas.fill(area, canvas.theme.palette.surface0);
    try std.testing.expectEqual(@as(usize, 1), fixture.quads.items().len);
    const plain = fixture.quads.items()[0];
    const bounds = canvas.rect(area);
    try std.testing.expectEqual(bounds.x, plain.x);
    try std.testing.expectEqual(bounds.width, plain.width);
    try std.testing.expectEqual(@as(f32, 0), plain.radius);
    try std.testing.expectEqual(@as(f32, 0), plain.border);
    try std.testing.expectEqual(@as(f32, 0), plain.reserved0);
    try std.testing.expectEqual(@as(f32, 0), plain.reserved1);
    try std.testing.expectEqual(@as(f32, 0), plain.border_a);
    var reference = QuadList.init(std.testing.allocator);
    defer reference.deinit();
    try reference.pushRect(bounds, plain_color(plain));
    try std.testing.expectEqualDeep(reference.items()[0], plain);
}

fn plain_color(item: Quad) @import("../render/Color.zig") {
    return .{ .r = item.r, .g = item.g, .b = item.b, .a = item.a };
}

test "rounded fills and rings are single quads carrying their shape" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    const area: core.Rect = .{ .x = 1, .y = 1, .w = 20, .h = 3 };
    try canvas.fillRounded(area, .{ .radius = 8, .color = .{ .rgb = .{ 10, 20, 30 } } });
    try canvas.ring(area, .{ .width = 2, .color = .{ .rgb = .{ 255, 200, 0 } } });
    try canvas.ring(area, .{ .width = 1, .radius = 8, .color = .{ .rgb = .{ 255, 255, 255 } } });
    try canvas.fillRounded(.{ .x = 0, .y = 0, .w = 0, .h = 3 }, .{ .radius = 8, .color = .default });
    try canvas.ring(.{ .x = 0, .y = 0, .w = 5, .h = 0 }, .{ .width = 2, .color = .default });
    const items = fixture.quads.items();
    try std.testing.expectEqual(@as(usize, 3), items.len);
    const bounds = canvas.rect(area);
    const card = items[0];
    try std.testing.expectEqual(bounds.x, card.x);
    try std.testing.expectEqual(bounds.y, card.y);
    try std.testing.expectEqual(bounds.width, card.width);
    try std.testing.expectEqual(bounds.height, card.height);
    try std.testing.expectEqual(@as(f32, 8), card.radius);
    try std.testing.expectEqual(@as(f32, 0), card.border);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0 / 255.0), card.r, 0.0001);
    try std.testing.expectEqual(@as(f32, 1), card.a);
    try std.testing.expectEqual(@as(f32, 0), card.border_a);
    try std.testing.expectEqual(card.u0, items[1].u0);
    const ring = items[1];
    try std.testing.expectEqual(bounds.width, ring.width);
    try std.testing.expectEqual(@as(f32, 0), ring.radius);
    try std.testing.expectEqual(@as(f32, 2), ring.border);
    try std.testing.expectEqual(@as(f32, 0), ring.a);
    try std.testing.expectEqual(@as(f32, 1), ring.border_r);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0 / 255.0), ring.border_g, 0.0001);
    try std.testing.expectEqual(@as(f32, 1), ring.border_a);
    const rounded_ring = items[2];
    try std.testing.expectEqual(@as(f32, 8), rounded_ring.radius);
    try std.testing.expectEqual(@as(f32, 1), rounded_ring.border);
    try std.testing.expectEqual(@as(f32, 0), rounded_ring.a);
    try std.testing.expectEqual(@as(f32, 1), rounded_ring.border_a);
}

test "sans labels measure proportional widths and clip at the area edge" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    const label = "Implement the GUI visual language";
    const mono_width = try canvas.measure(.{ .text = label });
    const sans_width = try canvas.measure(.{ .text = label, .face = .sans });
    try std.testing.expectEqual(@as(f32, @floatFromInt(label.len * 10)), mono_width);
    try std.testing.expect(sans_width > 0);
    try std.testing.expect(sans_width != mono_width);
    try std.testing.expect(@mod(sans_width, 10) != 0 or sans_width < mono_width);
    try std.testing.expectEqual(@as(usize, 0), fixture.quads.items().len);

    const wide: core.Rect = .{ .x = 1, .y = 2, .w = 60, .h = 1 };
    try canvas.text(wide, .{ .text = label, .face = .sans });
    const unclipped = try std.testing.allocator.dupe(Quad, fixture.quads.items());
    defer std.testing.allocator.free(unclipped);
    try std.testing.expect(unclipped.len > 0);
    var right: f32 = 0;
    for (unclipped) |item| {
        right = @max(right, item.x + item.width);
    }

    const origin = canvas.rect(wide);
    try std.testing.expect(right <= origin.x + sans_width + 2);
    try std.testing.expect(right > origin.x + sans_width - 12);

    const narrow: core.Rect = .{ .x = 1, .y = 2, .w = 6, .h = 1 };
    fixture.quads.clear();
    try canvas.text(narrow, .{ .text = label, .face = .sans, .underline = true });
    const bounds = canvas.rect(narrow);
    try std.testing.expect(fixture.quads.items().len > 0);
    try std.testing.expect(fixture.quads.items().len < unclipped.len);
    var underline = false;
    for (fixture.quads.items()) |item| {
        try std.testing.expect(item.x >= bounds.x and item.x + item.width <= bounds.x + bounds.width + 0.001);
        try std.testing.expect(item.y >= bounds.y and item.y + item.height <= bounds.y + bounds.height + 0.001);
        underline = underline or (item.height == 1 and item.width == bounds.width and item.y == bounds.y + bounds.height - 2);
    }

    try std.testing.expect(underline);
    const advance = try canvas.measure(.{ .text = label, .face = .sans });
    try std.testing.expectEqual(sans_width, advance);
}

test "bold sans selects the SemiBold face without synthetic emboldening" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    const area: core.Rect = .{ .x = 0, .y = 0, .w = 40, .h = 1 };
    try canvas.text(area, .{ .text = "agents", .face = .sans });
    const regular = try std.testing.allocator.dupe(Quad, fixture.quads.items());
    defer std.testing.allocator.free(regular);
    fixture.quads.clear();
    try canvas.text(area, .{ .text = "agents", .face = .sans, .bold = true });
    const semibold = fixture.quads.items();
    try std.testing.expectEqual(regular.len, semibold.len);
    try std.testing.expect(regular[0].u0 != semibold[0].u0 or regular[0].v0 != semibold[0].v0);
    try std.testing.expect(try canvas.measure(.{ .text = "agents", .face = .sans, .bold = true }) > try canvas.measure(.{ .text = "agents", .face = .sans }));
    try std.testing.expectEqual(Id.sans, fixture.atlas.shaping_cache.find(.{ .text = "agents", .face = .sans }).?.font);
    try std.testing.expectEqual(Id.sans_semibold, fixture.atlas.shaping_cache.find(.{ .text = "agents", .face = .sans_semibold }).?.font);
    var keys = fixture.atlas.glyphs.keyIterator();
    while (keys.next()) |key| {
        try std.testing.expectEqual(@as(u64, 0), key.* & 1);
    }

    const semibold_name = std.mem.span(@import("freetype").c.FT_Get_Postscript_Name(fixture.atlas.fonts.sans_semibold.face));
    try std.testing.expectEqualStrings("IBMPlexSans-SmBld", semibold_name);
    try std.testing.expectEqualStrings("IBMPlexSans", std.mem.span(@import("freetype").c.FT_Get_Postscript_Name(fixture.atlas.fonts.sans.face)));
}

test "terminal cells never select the sans face and sans glyphs never alias mono glyphs" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    try std.testing.expectEqual(Id.primary, fixture.atlas.fonts.source("A", .primary));
    try std.testing.expectEqual(Id.sans, fixture.atlas.fonts.source("A", .sans));
    try std.testing.expectEqual(Id.symbols, fixture.atlas.fonts.source("\u{f07b}", .sans));
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    _ = try fixture.atlas.place(.{ .text = "A", .x = 0, .y = 16, .color = .white, .pixel_height = 16 }, &list);
    const cell = list.items()[0];
    try canvas.text(.{ .x = 0, .y = 0, .w = 4, .h = 1 }, .{ .text = "A", .face = .sans });
    const sans = fixture.quads.items()[0];
    try std.testing.expect(cell.u0 != sans.u0 or cell.v0 != sans.v0);
    try std.testing.expectEqual(@as(u32, 2), fixture.atlas.glyphs.count());
    list.clear();
    _ = try fixture.atlas.place(.{ .text = "A", .x = 0, .y = 16, .color = .white, .pixel_height = 16 }, &list);
    try std.testing.expectEqualDeep(cell, list.items()[0]);
    const mixed = try canvas.measure(.{ .text = "A\u{f07b}", .face = .sans });
    try std.testing.expectEqual(try canvas.measure(.{ .text = "A", .face = .sans }) + 10, mixed);
}

test "warm sans labels shape rasterize and allocate nothing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    const labels = [_][]const u8{ "telar", "fix proxy tests", "hace 3m", "\u{f07b} agents \u{2801}" };
    for (labels) |label| {
        for (0..2) |bold| {
            try canvas.text(.{ .x = 0, .y = 0, .w = 60, .h = 1 }, .{ .text = label, .face = .sans, .bold = bold == 1 });
        }
    }

    const version = fixture.atlas.version;
    const calls = fixture.atlas.shape_calls;
    const rasters = fixture.atlas.raster_attempts;
    const count = fixture.quads.items().len;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    fixture.atlas.allocator = failing.allocator();
    fixture.quads.allocator = failing.allocator();
    defer fixture.atlas.allocator = std.testing.allocator;
    defer fixture.quads.allocator = std.testing.allocator;
    for (0..120) |_| {
        fixture.quads.clear();
        for (labels) |label| {
            for (0..2) |bold| {
                try canvas.text(.{ .x = 0, .y = 0, .w = 60, .h = 1 }, .{ .text = label, .face = .sans, .bold = bold == 1 });
                _ = try canvas.measure(.{ .text = label, .face = .sans, .bold = bold == 1 });
            }
        }
    }

    try std.testing.expectEqual(count, fixture.quads.items().len);
    try std.testing.expectEqual(version, fixture.atlas.version);
    try std.testing.expectEqual(calls, fixture.atlas.shape_calls);
    try std.testing.expectEqual(rasters, fixture.atlas.raster_attempts);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}
