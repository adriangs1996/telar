//! GUI-owned diagram requests and images, mutated only between native flights.
const std = @import("std");
const Request = @import("Request.zig");
const Job = @import("Job.zig");
const Completion = @import("Completion.zig");
const Entry = @import("Entry.zig");
const View = @import("view.zig").View;
const Store = @This();

pub const capacity = 8;
pub const max_pixels = 8 * 1024 * 1024;

allocator: std.mem.Allocator,
entries: [capacity]Entry = @splat(.{}),
wanted: [capacity]Entry = @splat(.{}),
frame: u64 = 1,
next_id: u64 = 1,
active: ?u64 = null,
retained_pixels: usize = 0,
revision: u64 = 0,

/// Example: `var store = Store.init(allocator); defer store.deinit();`
pub fn init(allocator: std.mem.Allocator) Store {
    return .{ .allocator = allocator };
}

pub fn deinit(store: *Store) void {
    for (&store.entries) |*entry| {
        store.release(entry);
    }
    for (&store.wanted) |*entry| {
        store.release(entry);
    }
}

/// Call after the previous native frame completes, before measuring this frame.
/// Example: `store.beginFrame();`
pub fn beginFrame(store: *Store) void {
    if (store.frame == std.math.maxInt(u64)) {
        for (&store.entries) |*entry| {
            entry.frame = 0;
        }
        store.frame = 0;
    }
    store.frame += 1;
}

/// Looks up frozen frame content without retaining offscreen resources.
/// Example: `if (store.lookup(request)) |view| draw(view);`
pub fn lookup(store: *Store, input: Request) ?View {
    for (&store.entries, 0..) |*entry, slot| {
        if (matches(entry, input)) {
            return view(entry, @intCast(slot));
        }
    }
    for (&store.wanted) |*entry| {
        if (matches(entry, input)) {
            return view(entry, 0);
        }
    }
    return null;
}

/// Protects a visible image until the current native frame has completed.
/// Example: `store.pin(request);`
pub fn pin(store: *Store, input: Request) void {
    for (&store.entries) |*entry| {
        if (matches(entry, input)) {
            entry.frame = store.frame;
            return;
        }
    }
}

/// Copies one visible request into a bounded replaceable slot. It does no I/O.
/// Example: `_ = store.request(request);`
pub fn request(store: *Store, input: Request) View {
    for (&store.entries, 0..) |*entry, slot| {
        if (matches(entry, input)) {
            entry.frame = store.frame;
            return view(entry, @intCast(slot));
        }
    }
    for (&store.wanted) |*entry| {
        if (matches(entry, input)) {
            entry.frame = store.frame;
            return view(entry, 0);
        }
    }
    if (input.text.len == 0 or !std.unicode.utf8ValidateSlice(input.text) or std.mem.indexOfScalar(u8, input.text, 0) != null) {
        return .{ .failed = .invalid };
    }
    if (input.text.len > Job.max_source_bytes or !std.math.isFinite(input.scale) or input.scale < 0.5 or input.scale > 4 or store.next_id == std.math.maxInt(u64)) {
        return .{ .failed = .limit };
    }
    if (store.available() == null) {
        return .{ .failed = .limit };
    }
    var empty: ?*Entry = null;
    for (&store.wanted) |*entry| {
        if (entry.source == null or entry.frame != store.frame) {
            empty = entry;
            break;
        }
    }
    const entry = empty orelse return .{ .failed = .limit };
    const source = store.allocator.dupe(u8, input.text) catch return .{ .failed = .limit };
    store.release(entry);
    entry.* = .{ .source = source, .kind = input.kind, .owner = input.owner, .block_offset = input.block_offset, .theme = input.theme, .scale = input.scale, .id = store.next_id, .frame = store.frame };
    store.next_id += 1;
    return .pending;
}

/// Starts at most one owned job, choosing only content requested in this frame.
/// Example: `if (store.nextJob()) |job| try service.start(job);`
pub fn nextJob(store: *Store) ?Job {
    store.admit();
    if (store.active != null) {
        return null;
    }
    for (&store.entries, 0..) |*entry, slot| {
        if (entry.source == null or entry.status != .pending or entry.frame != store.frame) {
            continue;
        }
        var job: Job = .{ .id = entry.id, .kind = entry.kind, .slot = @intCast(slot), .len = @intCast(entry.source.?.len), .theme = entry.theme, .scale = entry.scale };
        @memcpy(job.source[0..job.len], entry.source.?);
        entry.status = .running;
        store.active = entry.id;
        return job;
    }
    return null;
}

/// Exposes borrowed pixels only after preparation has finished replacing slots.
/// Example: `renderer.diagrams = store.textures();`
pub fn textures(store: *const Store) [capacity]@import("../native/native.zig").DiagramTexture {
    var result: [capacity]@import("../native/native.zig").DiagramTexture = @splat(.{});
    for (&store.entries, 0..) |*entry, slot| {
        if (entry.image) |image| {
            if (entry.frame != store.frame) {
                continue;
            }
            result[slot] = .{ .pixels = image.pixels.ptr, .width = image.width, .height = image.height, .version = entry.id };
        }
    }
    return result;
}

fn admit(store: *Store) void {
    for (&store.wanted) |*wanted| {
        if (wanted.source == null) {
            continue;
        }
        if (wanted.frame != store.frame) {
            store.release(wanted);
            continue;
        }
        if (wanted.status == .failed) {
            continue;
        }
        const slot = store.available() orelse {
            wanted.status = .failed;
            wanted.failure = .limit;
            store.revision +%= 1;
            continue;
        };
        store.release(&store.entries[slot]);
        store.entries[slot] = wanted.*;
        wanted.* = .{};
    }
}

/// Adopts a completed image only between native flights; stale results are freed.
/// Example: `_ = store.finish(completion);`
pub fn finish(store: *Store, completion: Completion) bool {
    if (store.active == null or store.active.? != completion.id) {
        store.discard(completion);
        return false;
    }
    store.active = null;
    store.revision +%= 1;
    for (&store.entries) |*entry| {
        if (entry.id != completion.id) {
            continue;
        }
        var image = completion.result catch |err| {
            entry.status = .failed;
            entry.failure = failure(err);
            return true;
        };
        if (!image.valid()) {
            image.deinit(store.allocator);
            entry.status = .failed;
            entry.failure = .limit;
            return true;
        }
        const pixels = @as(usize, image.width) * image.height;
        while (store.retained_pixels + pixels > max_pixels) {
            const victim = store.oldImage(entry) orelse {
                image.deinit(store.allocator);
                entry.status = .failed;
                entry.failure = .limit;
                return true;
            };
            store.release(victim);
        }
        entry.image = image;
        entry.status = .ready;
        store.retained_pixels += pixels;
        return true;
    }
    store.discard(completion);
    return false;
}

fn matches(entry: *const Entry, input: Request) bool {
    const source = entry.source orelse return false;
    const a = entry.owner;
    const b = input.owner;
    return entry.kind == input.kind and a.pane_id == b.pane_id and a.attachment_generation == b.attachment_generation and a.pane_generation == b.pane_generation and
        a.item_identity == b.item_identity and a.section == b.section and entry.block_offset == input.block_offset and
        entry.scale == input.scale and std.meta.eql(entry.theme, input.theme) and std.mem.eql(u8, source, input.text);
}

fn view(entry: *const Entry, slot: u8) View {
    return switch (entry.status) {
        .pending, .running => .pending,
        .failed => .{ .failed = entry.failure },
        .ready => .{ .ready = .{ .slot = slot, .width = entry.image.?.width, .height = entry.image.?.height, .logical_width = entry.image.?.logical_width, .logical_height = entry.image.?.logical_height } },
    };
}

fn available(store: *Store) ?usize {
    var oldest: ?usize = null;
    for (&store.entries, 0..) |*entry, index| {
        if (entry.source == null) {
            return index;
        }
        if (entry.status == .running or entry.frame == store.frame) {
            continue;
        }
        if (oldest == null or entry.frame < store.entries[oldest.?].frame) {
            oldest = index;
        }
    }
    return oldest;
}

fn oldImage(store: *Store, except: *Entry) ?*Entry {
    var oldest: ?*Entry = null;
    for (&store.entries) |*entry| {
        if (entry == except or entry.image == null or entry.frame == store.frame) {
            continue;
        }
        if (oldest == null or entry.frame < oldest.?.frame) {
            oldest = entry;
        }
    }
    return oldest;
}

fn release(store: *Store, entry: *Entry) void {
    if (entry.image) |*image| {
        store.retained_pixels -= @as(usize, image.width) * image.height;
        image.deinit(store.allocator);
    }
    if (entry.source) |source| {
        store.allocator.free(source);
    }
    entry.* = .{};
}

fn discard(store: *Store, completion: Completion) void {
    var image = completion.result catch return;
    image.deinit(store.allocator);
}

fn failure(err: anyerror) @import("view.zig").Failure {
    return switch (err) {
        error.UnsupportedDiagram => .unsupported,
        error.DiagramLimit, error.OutOfMemory => .limit,
        error.RendererUnavailable => .unavailable,
        error.Timeout, error.Canceled => .timeout,
        else => .invalid,
    };
}
