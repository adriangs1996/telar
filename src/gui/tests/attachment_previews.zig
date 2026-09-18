const std = @import("std");
const core = @import("telar-core");
const Fixture = @import("ConversationFixture.zig");
const Store = @import("../diagrams/Store.zig");
const Thumbnail = @import("../widgets/ComposerImage.zig");

test "four attachment previews keep aspect ratio and reuse textures across draft edits and resizing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var canvas = fixture.canvas();
    canvas.diagrams = &store;
    var images: core.AgentImages = .{};
    for ([_][]const u8{ "/tmp/a.png", "/tmp/b.png", "/tmp/c.png", "/tmp/d.png" }) |path| {
        try images.append(path);
    }
    var widget: Thumbnail = .{ .bounds = .{ .x = 10, .y = 20, .width = 72, .height = 72 }, .index = 0, .thread = .{ .pane_id = @enumFromInt(1), .agent = null, .composer = "", .composer_images = &images, .attachment_generation = 1 } };
    for (0..images.count) |index| {
        widget.index = @intCast(index);
        try widget.draw(&canvas);
        const job = store.nextJob() orelse return error.MissingImageJob;
        try std.testing.expectEqual(.local_image, job.kind);
        try std.testing.expectEqualStrings(images.path(index), job.text());
        const pixels = try std.testing.allocator.alloc(u8, 400 * 200 * 4);
        @memset(pixels, 255);
        try std.testing.expect(store.finish(.{ .id = job.id, .result = .{ .width = 400, .height = 200, .logical_width = 400, .logical_height = 200, .pixels = pixels } }));
    }
    store.beginFrame();
    fixture.quads.clear();
    widget.thread.composer_revision += 1;
    for (0..images.count) |index| {
        widget.index = @intCast(index);
        try widget.draw(&canvas);
    }
    var drawn: usize = 0;
    for (fixture.quads.items()) |quad| {
        if (quad.texture < 2) {
            continue;
        }
        drawn += 1;
        try std.testing.expectApproxEqAbs(@as(f32, 72), quad.width, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 36), quad.height, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 38), quad.y, 0.001);
    }
    try std.testing.expectEqual(@as(usize, 4), drawn);
    try std.testing.expect(store.nextJob() == null);
    try @import("../native/native.zig").DiagramTexture.validate(&store.textures());
    canvas.chrome.ratio = 2;
    widget.bounds.width = 20;
    try widget.draw(&canvas);
    try std.testing.expect(store.nextJob() == null);
}

test "attachment source identity cannot collide with a diagram containing the same text" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var request = @import("../widgets/interaction/ImagePreview.zig").requestFor(.{ .pane_id = @enumFromInt(1), .generation = 7, .path = "/tmp/image.png" });
    _ = store.request(request);
    request.kind = .mermaid;
    try std.testing.expect(store.lookup(request) == null);
    request.kind = .local_image;
    request.owner.attachment_generation += 1;
    try std.testing.expect(store.lookup(request) == null);
}
