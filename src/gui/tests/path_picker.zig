const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("OverlayFixture.zig");
const PathPicker = @import("../widgets/overlays/PathPicker.zig");

const paths = [_][]const u8{
    "apps/license-lookup-app/src/types/License.ts",
    "apps/license-lookup-app/src/app.d.ts",
    "apps/license-lookup-app/tests/test.ts",
    "apps/license-lookup-app/tests/test.ts-snapshots/",
    "apps/license-lookup-app/src/providers/stripe.ts",
    "apps/license-lookup-app/src/providers/types.ts",
    "apps/license-lookup-app/playwright.config.ts",
    "apps/license-lookup-app/src/providers/index.ts",
    "packages/licensing-core/src/index.ts",
    "apps/license-lookup-app/vite.config.ts",
    "README.md",
    "docs/",
};

fn open(fixture: *Fixture) !void {
    fixture.model.name_prompt.begin(.path_picker);
    const state = &fixture.model.path_picker;
    state.begin(@enumFromInt(10), "/work/replay-web");
    state.expect(3);

    var matches: [paths.len]core.PathMatch = undefined;
    for (paths, 0..) |relative, index| {
        matches[index] = .{
            .path = relative,
            .kind = if (relative[relative.len - 1] == '/') .directory else .file,
            .positions = if (index == 0) &.{ 34, 35, 36 } else &.{},
        };
    }

    var buffer: [8192]u8 = undefined;
    const encoded = try core.encodePathResults(&buffer, .{
        .request_id = @enumFromInt(3),
        .root = "/work/replay-web",
        .scanned = 2431,
        .matches = &matches,
    });
    try std.testing.expect(try state.receive((try core.decodeServer(encoded)).path_results));
}

test "native path picker stays inside every host and its rows choose their match" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try open(fixture);

    for ([_][2]u32{ .{ 120, 80 }, .{ 640, 360 }, .{ 1280, 720 }, .{ 1600, 1200 } }) |size| {
        fixture.size = try fixture.renderer.measure(.{
            .width = size[0],
            .height = size[1],
            .scale = 1,
        });
        try fixture.paint();
        for (fixture.renderer.quads.items()) |quad| {
            try std.testing.expect(quad.x >= 0 and quad.y >= 0);
            try std.testing.expect(quad.x + quad.width <= @as(f32, @floatFromInt(size[0])) + 0.001);
            try std.testing.expect(quad.y + quad.height <= @as(f32, @floatFromInt(size[1])) + 0.001);
        }
    }

    try std.testing.expect(fixture.overlays.presented().modal != null);
    const hits = &fixture.overlays.presented().palette;
    try std.testing.expectEqual(@as(u8, PathPicker.max_rows), hits.count);
    try std.testing.expectEqual(@as(u16, 0), hits.first);

    const row = hits.rows[1];
    const press = fixture.overlays.pointer(.{
        .x = row.x + 1,
        .y = row.y,
        .kind = .press,
    }).?;
    try std.testing.expectEqualDeep(client.Intent{ .prompt_row = 1 }, press.intent);
    _ = fixture.overlays.pointer(.{
        .x = row.x + 1,
        .y = row.y,
        .kind = .release,
    });
}

test "native path picker scrolls with the selection and keeps the page untouched" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try open(fixture);

    for (0..paths.len - 1) |_| {
        _ = fixture.model.name_prompt.apply(.move_down);
    }

    try fixture.paint();
    const hits = &fixture.overlays.presented().palette;
    try std.testing.expectEqual(@as(u16, paths.len - PathPicker.max_rows), hits.first);
    try std.testing.expectEqual(@as(u8, paths.len), fixture.model.path_picker.len);
    try std.testing.expectEqual(data.PathPickerState.Phase.ready, fixture.model.path_picker.phase);
}
