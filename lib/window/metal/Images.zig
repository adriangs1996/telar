//! Bounded image uploads on a separate serial queue. Pixels are borrowed until
//! takeCompletion; the window must stop frame work before accepting replacements.
const std = @import("std");
const gfx = @import("gfx");
const metal = @import("metal");
const c = @cImport({
    @cInclude("CoreFoundation/CFRunLoop.h");
});
const Images = @This();
const Upload = gfx.ImageUpload.ImageUpload;
const Status = enum(u8) { idle, uploading, ready, failed };
const Pixel = enum(u32) { rgb = 3, rgba = 4 };
const Deadline = enum(u64) { forever = std.math.maxInt(u64) };
const scratch_bytes = 1024 * 1024;
const Slot = struct {
    owner: *Images,
    texture: ?metal.Object = null,
    // SAFETY: accept assigns upload before publishing uploading status and scheduling the worker; idle slots never read it.
    upload: Upload = undefined,
    status: std.atomic.Value(Status) = .init(.idle),
};

device: metal.Object,
wake_source: c.CFRunLoopSourceRef,
queue: *anyopaque,
group: *anyopaque,
// SAFETY: init constructs every slot with its owner and idle state before returning Images or registering work.
slots: [gfx.ImageUpload.capacity]Slot = undefined,
// SAFETY: The serial image worker fills every RGBA byte of each row batch before uploading that batch; the scratch tail is not transferred.
scratch: [scratch_bytes]u8 = undefined,

pub fn init(device: metal.Object, source: c.CFRunLoopSourceRef) !*Images {
    const queue = dispatch_queue_create("telar.canvas.images", null) orelse return error.WorkerCreationFailed;
    errdefer dispatch_release(queue);
    const group = dispatch_group_create() orelse return error.WorkerCreationFailed;
    errdefer dispatch_release(group);
    const self = try std.heap.c_allocator.create(Images);
    self.* = .{ .device = device, .wake_source = source, .queue = queue, .group = group };
    for (&self.slots) |*slot| {
        slot.* = .{ .owner = self };
    }

    return self;
}

pub fn deinit(self: *Images) void {
    _ = dispatch_group_wait(self.group, @intFromEnum(Deadline.forever));
    for (self.slots) |slot| {
        if (slot.texture) |texture| {
            texture.release();
        }
    }

    dispatch_release(self.group);
    dispatch_release(self.queue);
    std.heap.c_allocator.destroy(self);
}

pub fn accept(self: *Images, uploads: []const Upload, releases: []const u32) void {
    for (releases) |handle| {
        const slot = self.find(handle) orelse continue;
        if (slot.status.load(.acquire) == .idle) {
            if (slot.texture) |texture| {
                texture.release();
                slot.texture = null;
            }
        }
    }

    for (uploads) |upload| {
        const slot = self.find(upload.handle) orelse continue;
        if (slot.status.load(.acquire) != .idle) {
            continue;
        }
        slot.upload = upload;
        if (upload.width == 0 or upload.height == 0 or upload.width > gfx.ImageUpload.max_side or upload.height > gfx.ImageUpload.max_side or (upload.bytes_per_pixel != @intFromEnum(Pixel.rgb) and upload.bytes_per_pixel != @intFromEnum(Pixel.rgba))) {
            slot.status.store(.failed, .release);
            self.wake();
            continue;
        }
        slot.status.store(.uploading, .release);
        dispatch_group_enter(self.group);
        dispatch_async_f(self.queue, slot, uploadImage);
    }
}

pub fn takeCompletion(self: *Images) ?gfx.ImageCompletion {
    for (&self.slots, 0..) |*slot, index| {
        const status = slot.status.load(.acquire);
        if (status == .ready or status == .failed) {
            slot.status.store(.idle, .release);
            return .{ .handle = @intCast(index + 1), .success = status == .ready };
        }
    }

    return null;
}

pub fn get(self: *Images, handle: u32) ?metal.Object {
    const slot = self.find(handle) orelse return null;
    return if (slot.status.load(.acquire) == .idle) slot.texture else null;
}

fn find(self: *Images, handle: u32) ?*Slot {
    return if (handle == 0 or handle > self.slots.len) null else &self.slots[handle - 1];
}

fn wake(self: *Images) void {
    c.CFRunLoopSourceSignal(self.wake_source);
    c.CFRunLoopWakeUp(c.CFRunLoopGetMain());
}

fn uploadImage(context: ?*anyopaque) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(context.?));
    const self = slot.owner;
    defer dispatch_group_leave(self.group);
    defer self.wake();
    const pool = metal.AutoreleasePool.init();
    defer pool.deinit();
    build(slot) catch {
        slot.status.store(.failed, .release);
        return;
    };
    slot.status.store(.ready, .release);
}

fn build(slot: *Slot) !void {
    const upload = slot.upload;
    if (slot.texture) |texture| {
        const size = metal.textureSize(texture);
        if (size.width != upload.width or size.height != upload.height) {
            return error.ImageSizeMismatch;
        }
    } else {
        slot.texture = try metal.createTexture(slot.owner.device, .{ .size = .{ .width = upload.width, .height = upload.height }, .format = .rgba8_unorm, .storage = .shared, .usage = .{ .shader_read = true } });
    }

    const stride = @as(usize, upload.width) * @intFromEnum(Pixel.rgba);
    if (upload.bytes_per_pixel == @intFromEnum(Pixel.rgba)) {
        metal.uploadTexture(slot.texture.?, .{ .size = .{ .width = upload.width, .height = upload.height } }, 0, upload.pixels, stride);
        return;
    }

    var top: usize = 0;
    const scratch = &slot.owner.scratch;
    while (top < upload.height) {
        const rows = @min(scratch.len / stride, upload.height - top);
        const source = upload.pixels + top * upload.width * @intFromEnum(Pixel.rgb);
        for (0..rows * upload.width) |i| {
            @memcpy(scratch[i * 4 ..][0..3], source[i * 3 ..][0..3]);
            scratch[i * 4 + 3] = 255;
        }

        metal.uploadTexture(slot.texture.?, .{ .origin = .{ .y = top }, .size = .{ .width = upload.width, .height = rows } }, 0, scratch, stride);
        top += rows;
    }
}

// libdispatch invokes uploadImage on the serial image queue. The group joins
// every reader of borrowed pixels before the surface and client can be freed.
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attributes: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_async_f(queue: *anyopaque, context: ?*anyopaque, function: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_group_create() ?*anyopaque;
extern "c" fn dispatch_group_enter(group: *anyopaque) void;
extern "c" fn dispatch_group_leave(group: *anyopaque) void;
extern "c" fn dispatch_group_wait(group: *anyopaque, deadline: u64) isize;
extern "c" fn dispatch_release(object: *anyopaque) void;
