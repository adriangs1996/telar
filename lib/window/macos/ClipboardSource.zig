//! A retained pasteboard for one media worker. No Window or GUI pointer crosses
//! threads. read returns owned PNG bytes; deinit releases the native reference.
const std = @import("std");
const objc = @import("objc");
const Limits = @import("../ClipboardLimits.zig");
const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("errno.h");
});
// ImageIO's umbrella headers contain Objective-C blocks, which translate-c
// cannot represent. These are the C ABI declarations used by this worker.
extern "c" fn CGImageSourceCreateWithData(data: c.CFDataRef, options: c.CFDictionaryRef) ?*anyopaque;
extern "c" fn CGImageSourceGetCount(source: *anyopaque) usize;
extern "c" fn CGImageSourceCopyPropertiesAtIndex(source: *anyopaque, index: usize, options: c.CFDictionaryRef) c.CFDictionaryRef;
extern "c" fn CGDataConsumerCreate(info: *anyopaque, callbacks: *const ConsumerCallbacks) ?*anyopaque;
extern "c" fn CGDataConsumerRelease(consumer: *anyopaque) void;
extern "c" fn CGImageDestinationCreateWithDataConsumer(consumer: *anyopaque, kind: c.CFStringRef, count: usize, options: c.CFDictionaryRef) ?*anyopaque;
const ConsumerCallbacks = extern struct {
    put_bytes: *const fn (*anyopaque, [*]const u8, usize) callconv(.c) usize,
    release: ?*const fn (*anyopaque) callconv(.c) void = null,
};
const PngWriter = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    limit: usize,
    failure: ?anyerror = null,
};
extern "c" fn CGImageDestinationAddImageFromSource(destination: *anyopaque, source: *anyopaque, index: usize, options: c.CFDictionaryRef) void;
extern "c" fn CGImageDestinationFinalize(destination: *anyopaque) bool;
extern "c" var kCGImagePropertyPixelWidth: c.CFStringRef;
extern "c" var kCGImagePropertyPixelHeight: c.CFStringRef;
const ClipboardSource = @This();
const file_limit = 16;
extern "c" var NSPasteboardTypePNG: objc.c.id;
extern "c" var NSPasteboardTypeTIFF: objc.c.id;
extern "c" var NSPasteboardURLReadingFileURLsOnlyKey: objc.c.id;
board: objc.Object,
revision: ?isize = null,

pub fn deinit(self: *ClipboardSource) void {
    self.board.release();
    self.* = undefined;
}

/// Materializes pasteboard data on the media worker, validates dimensions before
/// decoding, and normalizes PNG/TIFF/JPEG or owned regular file URLs to PNG.
/// AppKit can materialize provider data before its length is available; all
/// subsequent copies, decoding and PNG output obey the client's explicit quotas.
pub fn read(self: ClipboardSource, gpa: std.mem.Allocator, limits: Limits) ![]u8 {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    if (self.revision) |revision| {
        if (self.board.msgSend(isize, "changeCount", .{}) != revision) {
            return error.ClipboardChanged;
        }
    }
    var failure: anyerror = error.NoImageOnClipboard;
    const source = (try self.fileSource(limits, &failure)) orelse (try self.dataSource(limits, &failure)) orelse return failure;
    defer c.CFRelease(source);
    if (self.revision) |revision| {
        if (self.board.msgSend(isize, "changeCount", .{}) != revision) {
            return error.ClipboardChanged;
        }
    }
    try dimensions(source, limits.pixels);
    var writer: PngWriter = .{ .gpa = gpa, .limit = limits.png_bytes };
    defer {
        std.crypto.secureZero(u8, writer.bytes.items);
        writer.bytes.deinit(gpa);
    }
    const callbacks: ConsumerCallbacks = .{ .put_bytes = writePng };
    const consumer = CGDataConsumerCreate(&writer, &callbacks) orelse return error.OutOfMemory;
    defer CGDataConsumerRelease(consumer);
    const png_type = c.CFStringCreateWithCString(null, "public.png", c.kCFStringEncodingUTF8) orelse return error.OutOfMemory;
    defer c.CFRelease(png_type);
    const destination = CGImageDestinationCreateWithDataConsumer(consumer, png_type, 1, null) orelse return error.ClipboardReadFailed;
    defer c.CFRelease(destination);
    CGImageDestinationAddImageFromSource(destination, source, 0, null);
    const success = CGImageDestinationFinalize(destination);
    if (writer.failure) |write_failure| {
        return write_failure;
    }
    if (!success or writer.bytes.items.len == 0) {
        return error.ClipboardReadFailed;
    }
    return writer.bytes.toOwnedSlice(gpa);
}

// ImageIO calls this synchronously during encoding. Refuse output before its
// allocation would exceed the PNG quota, retaining the precise failure reason.
fn writePng(info: *anyopaque, bytes: [*]const u8, count: usize) callconv(.c) usize {
    const writer: *PngWriter = @ptrCast(@alignCast(info));
    if (writer.failure != null) {
        return 0;
    }
    if (count > writer.limit -| writer.bytes.items.len) {
        writer.failure = error.ClipboardPngTooLarge;
        return 0;
    }
    const capacity = @min(writer.limit, @max(writer.bytes.items.len + count, writer.bytes.capacity +| (writer.bytes.capacity / 2) +| 64));
    writer.bytes.ensureTotalCapacityPrecise(writer.gpa, capacity) catch |err| {
        writer.failure = err;
        return 0;
    };
    writer.bytes.appendSliceAssumeCapacity(bytes[0..count]);
    return count;
}

fn dimensions(source: *anyopaque, max_pixels: u64) !void {
    const properties = CGImageSourceCopyPropertiesAtIndex(source, 0, null) orelse return error.ClipboardReadFailed;
    defer c.CFRelease(properties);
    const width_value = c.CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth) orelse return error.ClipboardReadFailed;
    const height_value = c.CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight) orelse return error.ClipboardReadFailed;
    var width: i64 = 0;
    var height: i64 = 0;
    if (c.CFNumberGetValue(@ptrCast(width_value), c.kCFNumberSInt64Type, &width) == 0 or c.CFNumberGetValue(@ptrCast(height_value), c.kCFNumberSInt64Type, &height) == 0 or width <= 0 or height <= 0) {
        return error.InvalidClipboardImage;
    }
    if (width > std.math.maxInt(u32) or height > std.math.maxInt(u32) or @as(u64, @intCast(width)) > max_pixels / @as(u64, @intCast(height))) {
        return error.ClipboardPixelsTooLarge;
    }
}

fn dataSource(self: ClipboardSource, limits: Limits, failure: *anyerror) !?*anyopaque {
    const jpeg = objc.getClass("NSString").?.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*:0]const u8, "public.jpeg")});
    for ([_]objc.c.id{ NSPasteboardTypePNG, NSPasteboardTypeTIFF, jpeg.value }) |kind| {
        const data = self.board.msgSend(objc.c.id, "dataForType:", .{kind});
        if (data == null) {
            continue;
        }
        const count = objc.Object.fromId(data).msgSend(usize, "length", .{});
        if (count > limits.source_bytes) {
            failure.* = error.ClipboardSourceTooLarge;
            continue;
        }
        if (count == 0) {
            continue;
        }
        failure.* = error.ClipboardReadFailed;
        if (CGImageSourceCreateWithData(@ptrCast(data), null)) |source| {
            if (CGImageSourceGetCount(source) != 0) {
                return source;
            }
            c.CFRelease(source);
        }
    }
    return null;
}

fn fileSource(self: ClipboardSource, limits: Limits, failure: *anyerror) !?*anyopaque {
    const classes = objc.getClass("NSArray").?.msgSend(objc.Object, "arrayWithObject:", .{objc.getClass("NSURL").?});
    const yes = objc.getClass("NSNumber").?.msgSend(objc.Object, "numberWithBool:", .{true});
    const options = objc.getClass("NSDictionary").?.msgSend(objc.Object, "dictionaryWithObject:forKey:", .{ yes, NSPasteboardURLReadingFileURLsOnlyKey });
    const urls = self.board.msgSend(objc.Object, "readObjectsForClasses:options:", .{ classes, options });
    for (0..@min(file_limit, urls.msgSend(usize, "count", .{}))) |i| {
        const url = urls.msgSend(objc.Object, "objectAtIndex:", .{i});
        const path = url.msgSend(?[*:0]const u8, "fileSystemRepresentation", .{}) orelse continue;
        if (try sourceFromFile(path, limits, failure)) |source| {
            return source;
        }
    }
    return null;
}

// Never follow a symlink, block on a FIFO, or read a file owned by another user.
// fstat applies to the opened descriptor, so replacing the pathname cannot
// substitute another file between validation and the bounded read.
fn sourceFromFile(path: [*:0]const u8, limits: Limits, failure: *anyerror) !?*anyopaque {
    const fd = c.open(path, @as(c_int, c.O_RDONLY | c.O_NOFOLLOW | c.O_NONBLOCK | c.O_CLOEXEC));
    if (fd < 0) {
        return null;
    }
    defer _ = c.close(fd);
    // SAFETY: fstat fills status on success; short-circuit checks prevent all field reads on failure.
    var status: c.struct_stat = undefined;
    if (c.fstat(fd, &status) != 0 or status.st_mode & c.S_IFMT != c.S_IFREG or status.st_uid != c.geteuid() or status.st_size <= 0) {
        return null;
    }
    if (@as(u64, @intCast(status.st_size)) > limits.source_bytes) {
        failure.* = error.ClipboardSourceTooLarge;
        return null;
    }
    const data = c.CFDataCreateMutable(null, @intCast(status.st_size)) orelse return error.OutOfMemory;
    defer c.CFRelease(data);
    c.CFDataSetLength(data, @intCast(status.st_size));
    const bytes = c.CFDataGetMutableBytePtr(data)[0..@intCast(status.st_size)];
    defer std.crypto.secureZero(u8, bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (count < 0 and c.__error().* == c.EINTR) {
            continue;
        }
        if (count <= 0) {
            failure.* = error.ClipboardReadFailed;
            return null;
        }
        offset += @intCast(count);
    }
    // ImageIO may lazily borrow the CFData, so it must retain its own immutable
    // copy before this function clears the source buffer.
    const copy = c.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.OutOfMemory;
    defer c.CFRelease(copy);
    const source = CGImageSourceCreateWithData(copy, null) orelse return null;
    if (CGImageSourceGetCount(source) == 0) {
        c.CFRelease(source);
        return null;
    }
    return source;
}
