const std = @import("std");
const Store = @import("Store.zig");
const Service = @import("Service.zig");
const Request = @import("Request.zig");
const Image = @import("Image.zig");
const source = "flowchart TD\nA --> B";

test "diagram admission cannot replace any texture measured and pinned for the current frame" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    for (0..Store.capacity) |index| {
        store.beginFrame();
        try load(&store, request(index + 1, source), 1);
    }
    store.beginFrame();
    const ninth = request(9, source);
    try std.testing.expectEqual(.pending, store.request(ninth));
    for (0..Store.capacity) |index| {
        const input = request(index + 1, source);
        try std.testing.expect(store.lookup(input).? == .ready);
        store.pin(input);
    }
    const frozen = store.textures();
    const revision = store.revision;
    try std.testing.expect(store.nextJob() == null);
    try std.testing.expectEqual(.limit, store.lookup(ninth).?.failed);
    try std.testing.expect(store.revision != revision);
    const after = store.textures();
    try std.testing.expect(std.meta.eql(frozen, after));
    for (frozen) |texture| {
        try std.testing.expectEqual(@as(u8, 255), texture.pixels.?[0]);
    }
    store.beginFrame();
    _ = store.request(ninth);
    try std.testing.expect(store.nextJob() == null);
}

test "diagram admission evicts only after painting and preserves an explicitly pinned slot" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    for (0..Store.capacity) |index| {
        store.beginFrame();
        try load(&store, request(index + 1, source), 1);
    }
    store.beginFrame();
    const retained = request(1, source);
    const slot = store.lookup(retained).?.ready.slot;
    store.pin(retained);
    const pinned = store.textures()[slot];
    const newcomer = request(9, source);
    try std.testing.expectEqual(.pending, store.request(newcomer));
    for (0..Store.capacity) |index| {
        try std.testing.expect(store.lookup(request(index + 1, source)).? == .ready);
    }
    const job = store.nextJob() orelse return error.MissingDiagramJob;
    try std.testing.expect(job.slot != slot);
    try std.testing.expect(std.meta.eql(pinned, store.textures()[slot]));
    try std.testing.expectEqual(@as(u8, 255), pinned.pixels.?[0]);
}

test "active diagram jobs own source bytes and stale completions cannot clear another job" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var mutable = source.*;
    var current = request(1, &mutable);
    _ = store.request(current);
    const first = store.nextJob() orelse return error.MissingDiagramJob;
    mutable[mutable.len - 1] = 'C';
    current.owner.snapshot_revision += 1;
    _ = store.request(current);
    try std.testing.expect(store.nextJob() == null);
    try std.testing.expectEqualStrings(source, first.text());
    try std.testing.expect(store.lookup(request(1, source)).? == .pending);
    try std.testing.expect(store.lookup(current).? == .pending);
    try std.testing.expect(!store.finish(.{ .id = first.id + 100, .result = try makeImage(std.testing.allocator, 1) }));
    try std.testing.expectEqual(first.id, store.active.?);
    try std.testing.expect(store.finish(.{ .id = first.id, .result = try makeImage(std.testing.allocator, 1) }));
    const second = store.nextJob() orelse return error.MissingDiagramJob;
    try std.testing.expect(second.id != first.id);
    try std.testing.expectEqualStrings("flowchart TD\nA --> C", second.text());
    try std.testing.expect(!store.finish(.{ .id = first.id, .result = try makeImage(std.testing.allocator, 1) }));
    try std.testing.expectEqual(second.id, store.active.?);
    try std.testing.expect(store.lookup(current).? == .pending);
    try std.testing.expect(store.finish(.{ .id = second.id, .result = error.UnsupportedDiagram }));
    try std.testing.expectEqual(.unsupported, store.lookup(current).?.failed);
}

test "diagram identity includes every owner boundary and exact source but ignores snapshot pool movement" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const initial = request(1, source);
    try load(&store, initial, 1);
    var revised = initial;
    revised.owner.snapshot_revision += 1;
    revised.owner.source_offset += 100;
    try std.testing.expect(store.lookup(revised).? == .ready);
    for (0..9) |change| {
        var changed = initial;
        switch (change) {
            0 => changed.owner.pane_id = @enumFromInt(2),
            1 => changed.owner.attachment_generation += 1,
            2 => changed.owner.pane_generation += 1,
            3 => changed.owner.item_identity += 1,
            4 => changed.owner.section = .metadata,
            5 => changed.block_offset += 1,
            6 => changed.theme.bg[0] +%= 1,
            7 => changed.scale = 2,
            8 => changed.text = "flowchart TD\nA --> C",
            else => unreachable,
        }
        try std.testing.expect(store.lookup(changed) == null);
    }
}

test "diagram allocation failure preserves ready content and permits a later bounded retry" {
    var accounting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var store = Store.init(accounting.allocator());
    defer store.deinit();
    const initial = request(1, source);
    try load(&store, initial, 1);
    const revision = store.revision;
    const allocated = accounting.allocated_bytes;
    accounting.fail_index = accounting.alloc_index;
    try std.testing.expectEqual(.limit, store.request(request(2, source)).failed);
    try std.testing.expect(store.lookup(initial).? == .ready);
    try std.testing.expectEqual(revision, store.revision);
    try std.testing.expectEqual(allocated, accounting.allocated_bytes);
    try std.testing.expect(store.nextJob() == null);
    for (0..3) |_| {
        _ = store.lookup(initial);
        store.pin(initial);
        _ = store.request(initial);
        _ = store.textures();
    }
    try std.testing.expectEqual(allocated, accounting.allocated_bytes);
    accounting.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(.pending, store.request(request(2, source)));
    try std.testing.expect(store.nextJob() != null);
}

test "diagram quota rejects a completion when all existing pixels remain pinned" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try load(&store, request(1, source), 2048);
    try load(&store, request(2, source), 2048);
    try std.testing.expectEqual(@as(usize, Store.max_pixels), store.retained_pixels);
    store.pin(request(1, source));
    store.pin(request(2, source));
    const protected = store.textures();
    _ = store.request(request(3, source));
    const job = store.nextJob() orelse return error.MissingDiagramJob;
    try std.testing.expect(store.finish(.{ .id = job.id, .result = try makeImage(std.testing.allocator, 1) }));
    try std.testing.expectEqual(.limit, store.lookup(request(3, source)).?.failed);
    try std.testing.expectEqual(@as(usize, Store.max_pixels), store.retained_pixels);
    try std.testing.expect(std.meta.eql(protected, store.textures()));
}

test "diagram service expires prior frame pins before adopting a notified result at the pixel quota" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    try load(&service.store, request(1, source), 2048);
    try load(&service.store, request(2, source), 2048);
    service.store.pin(request(1, source));
    service.store.pin(request(2, source));
    _ = service.store.request(request(3, source));
    const job = service.store.nextJob() orelse return error.MissingDiagramJob;
    service.job = job;
    service.result = .{ .id = job.id, .result = try makeImage(std.testing.allocator, 1) };
    service.notify();
    try std.testing.expect(service.store.lookup(request(3, source)).? == .pending);
    service.beginFrame();
    try std.testing.expect(service.store.lookup(request(3, source)).? == .ready);
    try std.testing.expect(service.store.retained_pixels <= Store.max_pixels);
    try std.testing.expect(service.job == null and service.result == null and !service.notified);
}

test "diagram service frees an owned image when inbox shutdown drops its completion notification" {
    var accounting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var service = Service.init(accounting.allocator());
        defer service.deinit();
        var inbox: @import("../gui_event.zig").Inbox = .init(std.testing.io, .{});
        defer inbox.deinit();
        const ticket = try inbox.reserve();
        _ = service.store.request(request(1, source));
        const job = service.store.nextJob() orelse return error.MissingDiagramJob;
        service.job = job;
        service.result = .{ .id = job.id, .result = try protocolImage(accounting.allocator()) };
        inbox.close();
        try std.testing.expect(!inbox.publish(ticket, .diagram_ready));
        try std.testing.expectEqual(@as(usize, 0), inbox.snapshot().depth);
        try std.testing.expect(!service.notified);
    }
    try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
}

test "diagram service rolls back worker admission when the inbox is closed" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    var inbox: @import("../gui_event.zig").Inbox = .init(std.testing.io, .{});
    defer inbox.deinit();
    inbox.close();
    _ = service.store.request(request(1, source));
    service.start(&inbox);
    try std.testing.expectEqual(.unavailable, service.store.lookup(request(1, source)).?.failed);
    try std.testing.expect(service.store.active == null);
    try std.testing.expect(service.job == null and service.result == null and !service.notified);
    for (0..3) |_| {
        service.start(&inbox);
    }
    const snapshot = inbox.snapshot();
    try std.testing.expectEqual(@as(usize, 0), snapshot.depth);
    try std.testing.expectEqual(@as(usize, 0), snapshot.reserved);
}

test "diagram service retains completion ownership until notification and frame preparation" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    _ = service.store.request(request(1, source));
    const job = service.store.nextJob() orelse return error.MissingDiagramJob;
    service.job = job;
    service.result = .{ .id = job.id, .result = try makeImage(std.testing.allocator, 4) };
    service.beginFrame();
    try std.testing.expect(service.result != null);
    try std.testing.expect(service.store.lookup(request(1, source)).? == .pending);
    service.notify();
    try std.testing.expect(service.store.lookup(request(1, source)).? == .pending);
    service.beginFrame();
    try std.testing.expect(service.store.lookup(request(1, source)).? == .ready);
    try std.testing.expect(service.result == null and service.job == null);
}

test "diagram requests that leave the viewport before admission never launch and settled frames stay idle" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expect(store.nextJob() == null);
    _ = store.request(request(1, source));
    store.beginFrame();
    try std.testing.expect(store.nextJob() == null);
    try std.testing.expect(store.lookup(request(1, source)) == null);
    _ = store.request(request(1, source));
    const job = store.nextJob() orelse return error.MissingDiagramJob;
    try std.testing.expect(store.finish(.{ .id = job.id, .result = error.InvalidDiagram }));
    for (0..4) |_| {
        store.beginFrame();
        try std.testing.expectEqual(.invalid, store.request(request(1, source)).failed);
        try std.testing.expect(store.nextJob() == null);
    }
}

test "invalid diagram sources geometry and malformed result buffers never enter retained storage" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    for ([_][]const u8{ "", "x\x00y", "\xff" }) |text| {
        try std.testing.expectEqual(.invalid, store.request(request(1, text)).failed);
    }
    var too_long: [@import("Job.zig").max_source_bytes + 1]u8 = @splat('x');
    try std.testing.expectEqual(.limit, store.request(request(1, &too_long)).failed);
    for ([_]f32{ 0, 0.49, 4.01, std.math.inf(f32), std.math.nan(f32) }) |scale| {
        var input = request(1, source);
        input.scale = scale;
        try std.testing.expectEqual(.limit, store.request(input).failed);
    }
    try std.testing.expect(store.nextJob() == null);
    _ = store.request(request(1, source));
    const job = store.nextJob() orelse return error.MissingDiagramJob;
    var image = try makeImage(std.testing.allocator, 1);
    image.width = std.math.maxInt(u32);
    try std.testing.expect(store.finish(.{ .id = job.id, .result = image }));
    try std.testing.expectEqual(.limit, store.lookup(request(1, source)).?.failed);
    try std.testing.expectEqual(@as(usize, 0), store.retained_pixels);
}

fn request(identity: u64, text: []const u8) Request {
    return .{ .owner = .{ .pane_id = @enumFromInt(1), .attachment_generation = 1, .pane_generation = 1, .snapshot_revision = 1, .item_identity = identity, .section = .body, .source_offset = 0 }, .block_offset = 0, .text = text, .theme = .{ .bg = .{ 20, 20, 20 }, .fg = .{ 240, 240, 240 }, .accent = .{ 90, 150, 230 } }, .scale = 1 };
}

fn makeImage(allocator: std.mem.Allocator, side: u32) !Image {
    const pixels = try allocator.alloc(u8, @as(usize, side) * side * 4);
    @memset(pixels, 255);
    return .{ .width = side, .height = side, .logical_width = @floatFromInt(side), .logical_height = @floatFromInt(side), .pixels = pixels };
}

fn load(store: *Store, input: Request, side: u32) !void {
    _ = store.request(input);
    const job = store.nextJob() orelse return error.MissingDiagramJob;
    try std.testing.expect(store.finish(.{ .id = job.id, .result = try makeImage(store.allocator, side) }));
}

fn protocolImage(allocator: std.mem.Allocator) !Image {
    const bytes = try allocator.alloc(u8, @import("protocol.zig").header_bytes + 4);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "TLRD");
    std.mem.writeInt(u32, bytes[4..8], 1, .little);
    std.mem.writeInt(u32, bytes[8..12], 1, .little);
    std.mem.writeInt(u32, bytes[12..16], @bitCast(@as(f32, 1)), .little);
    std.mem.writeInt(u32, bytes[16..20], @bitCast(@as(f32, 1)), .little);
    return @import("protocol.zig").decode(bytes);
}
