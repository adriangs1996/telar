//! A terminal-browser style shared-memory frame crosses the runtime with one
//! copy: the child's object lands in a runtime-owned object whose mapping is
//! the emulator's storage and, for local clients, the parked transfer.

const std = @import("std");
const core = @import("telar-core");
const backend_media = @import("../../media/root.zig");
const pane_mod = @import("../../pane/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const media_projection = @import("../entrypoints/events/pane/media_projection.zig");
const support = @import("support.zig");

const shared_memory_supported = pane_mod.shared_transfer.shared_memory_supported;
const AttachmentStore = attachment_mod.AttachmentStore;

fn createChildObject(name: [:0]const u8, pixels: []const u8) !void {
    const fd = std.c.shm_open(
        name,
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
        @as(u16, 0o600),
    );
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(fd));
    defer _ = std.c.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), std.c.ftruncate(fd, @intCast(pixels.len)));
    const map = try std.posix.mmap(
        null,
        pixels.len,
        .{ .READ = true, .WRITE = true },
        std.c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(map);
    @memcpy(map[0..pixels.len], pixels);
}

fn objectExists(name: [:0]const u8) bool {
    const fd = std.c.shm_open(name, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    if (std.posix.errno(fd) != .SUCCESS) return false;
    _ = std.c.close(fd);
    return true;
}

fn readObject(name: [:0]const u8, buffer: []u8) !void {
    const fd = std.c.shm_open(name, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(fd));
    defer _ = std.c.close(fd);
    const map = try std.posix.mmap(null, buffer.len, .{ .READ = true }, std.c.MAP{ .TYPE = .SHARED }, fd, 0);
    defer std.posix.munmap(map);
    @memcpy(buffer, map[0..buffer.len]);
}

const Frame = struct {
    name_buffer: [64]u8 = undefined,
    name_len: usize = 0,
    envelope: [256]u8 = undefined,
    envelope_len: usize = 0,

    fn name(frame: *const Frame) [:0]const u8 {
        return frame.name_buffer[0..frame.name_len :0];
    }

    fn bytes(frame: *const Frame) []const u8 {
        return frame.envelope[0..frame.envelope_len];
    }

    /// Publishes `pixels` the way terminal-browser does: a fresh object and
    /// one synchronized envelope naming it.
    fn publish(frame: *Frame, sequence: u32, pixels: []const u8) !void {
        const name_z = try std.fmt.bufPrintZ(&frame.name_buffer, "/tlrtest-frame-{d}-{d}", .{ std.c.getpid(), sequence });
        frame.name_len = name_z.len;
        _ = std.c.shm_unlink(name_z);
        try createChildObject(name_z, pixels);
        const Encoder = std.base64.standard.Encoder;
        var encoded: [128]u8 = undefined;
        const payload = Encoder.encode(encoded[0..Encoder.calcSize(name_z.len)], name_z);
        const envelope = try std.fmt.bufPrint(
            &frame.envelope,
            "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=2,v=1,t=s,i=7,p=1,C=1,q=2;{s}\x1b\\\x1b[?2026l",
            .{payload},
        );
        frame.envelope_len = envelope.len;
    }
};

fn ingest(fixture: *support.PaneFixture, bytes: []const u8) !backend_media.Stats {
    fixture.pane.media.queueOutput(bytes);
    try std.testing.expect(fixture.pane.media.seal());
    var stats: backend_media.Stats = .{};
    fixture.pane.processMedia(fixture.pane.size, &stats);
    fixture.pane.media.finishSealed();
    return stats;
}

test "a shared frame is copied once into the object that becomes emulator storage" {
    if (comptime !shared_memory_supported) return error.SkipZigTest;
    var fixture: support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = fixture.attachments.configureGraphics(true);
    const pixels = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255 };
    var frame: Frame = .{};
    try frame.publish(1, &pixels);
    defer _ = std.c.shm_unlink(frame.name());
    const used_before = fixture.pane.media_allocator.used;

    const stats = try ingest(&fixture, frame.bytes());

    try std.testing.expectEqual(@as(u64, 1), stats.forwarded_frames);
    try std.testing.expectEqual(@as(u64, 1), stats.direct_frames);
    try std.testing.expect(!objectExists(frame.name()));
    const storage = &fixture.pane.media.terminal.screens.active.kitty_images;
    const image = storage.imageById(7) orelse return error.ImageMissing;
    const resolved = fixture.pane.media_allocator.imagePixels(image.data.bytes()) orelse return error.PixelsMissing;
    try std.testing.expectEqualSlices(u8, &pixels, resolved);
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
    // The emulator holds a placeholder; the pixels are the mapping itself.
    const mapping = fixture.pane.media_allocator.mappings[0] orelse return error.MappingMissing;
    try std.testing.expectEqual(mapping.pixels.ptr, resolved.ptr);
    try std.testing.expectEqual(@as(usize, 1), image.data.bytes().?.len);
    try std.testing.expect(fixture.pane.media_allocator.used >= used_before + pixels.len);
    const used_after_first = fixture.pane.media_allocator.used;

    const key: core.graphics.ImageKey = .{ .image_id = 7, .generation = image.generation };
    try std.testing.expect(fixture.pane.prepared_transfers.holds(key));
    const parked = fixture.pane.prepared_transfers.items[0].?;
    try std.testing.expectEqual(@as(usize, 0), parked.reserved_len);
    var contents: [pixels.len]u8 = undefined;
    try readObject(parked.name.sliceZ(), &contents);
    try std.testing.expectEqualSlices(u8, &pixels, &contents);

    // The attachment adopts the parked object without another copy.
    fixture.pane.refreshGraphicsProjection();
    const stores = [_]*AttachmentStore{&fixture.attachments};
    const projection = media_projection.synchronize(fixture.pane, &stores, false);
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    try std.testing.expectEqual(@as(u64, 1), projection.staged);
    try std.testing.expectEqual(@as(u32, 1), attachment.graphics.adopted);
    try std.testing.expectEqualStrings(parked.name.slice(), attachment.graphics.transfer.?.shared_name.?.slice());
    // Adoption reserved nothing more: the mapping already pays for the object.
    try std.testing.expectEqual(used_after_first, fixture.pane.media_allocator.used);
}

test "replacing a direct frame unmaps the previous object and keeps quota flat" {
    if (comptime !shared_memory_supported) return error.SkipZigTest;
    var fixture: support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = fixture.attachments.configureGraphics(true);
    const first_pixels = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255 };
    const second_pixels = [_]u8{ 9, 9, 9, 255, 8, 8, 8, 255 };
    var first: Frame = .{};
    try first.publish(2, &first_pixels);
    defer _ = std.c.shm_unlink(first.name());
    _ = try ingest(&fixture, first.bytes());
    const first_parked = fixture.pane.prepared_transfers.items[0].?.name;
    const used_after_first = fixture.pane.media_allocator.used;

    var second: Frame = .{};
    try second.publish(3, &second_pixels);
    defer _ = std.c.shm_unlink(second.name());
    const stats = try ingest(&fixture, second.bytes());

    try std.testing.expectEqual(@as(u64, 1), stats.direct_frames);
    const image = fixture.pane.media.terminal.screens.active.kitty_images.imageById(7) orelse
        return error.ImageMissing;
    try std.testing.expectEqualSlices(u8, &second_pixels, fixture.pane.media_allocator.imagePixels(image.data.bytes()).?);
    try std.testing.expectEqual(used_after_first, fixture.pane.media_allocator.used);
    // The unadopted first object went with its generation.
    try std.testing.expect(!objectExists(first_parked.sliceZ()));
    var mapped: usize = 0;
    for (fixture.pane.media_allocator.mappings) |slot| mapped += @intFromBool(slot != null);
    try std.testing.expectEqual(@as(usize, 1), mapped);
}

test "without a shared-transport client the frame still loads with one copy and parks nothing" {
    if (comptime !shared_memory_supported) return error.SkipZigTest;
    var fixture: support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const pixels = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255 };
    var frame: Frame = .{};
    try frame.publish(4, &pixels);
    defer _ = std.c.shm_unlink(frame.name());

    const stats = try ingest(&fixture, frame.bytes());

    try std.testing.expectEqual(@as(u64, 1), stats.direct_frames);
    try std.testing.expectEqual(@as(u64, 0), stats.prepared_frames);
    for (fixture.pane.prepared_transfers.items) |slot| try std.testing.expect(slot == null);
    const image = fixture.pane.media.terminal.screens.active.kitty_images.imageById(7) orelse
        return error.ImageMissing;
    try std.testing.expectEqualSlices(u8, &pixels, fixture.pane.media_allocator.imagePixels(image.data.bytes()).?);
}
