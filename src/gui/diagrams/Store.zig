//! GUI-owned diagram requests and images, mutated only between native flights.
const native = @import("../native/native.zig");
const view_module = @import("view.zig");
const std = @import("std");
const Request = @import("Request.zig");
const Job = @import("Job.zig");
const Completion = @import("Completion.zig");
const Entry = @import("Entry.zig");
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

pub fn deinit(self: *Store) void {
    for (&self.entries) |*entry| {
        self.release(entry);
    }
    for (&self.wanted) |*entry| {
        self.release(entry);
    }
}

/// Call after the previous native frame completes, before measuring this frame.
/// Example: `store.beginFrame();`
pub fn beginFrame(self: *Store) void {
    if (self.frame == std.math.maxInt(u64)) {
        for (&self.entries) |*entry| {
            entry.frame = 0;
        }
        self.frame = 0;
    }
    self.frame += 1;
}

/// Looks up frozen frame content without retaining offscreen resources.
/// Example: `if (store.lookup(request)) |view| draw(view);`
pub fn lookup(self: *Store, input: Request) ?view_module.View {
    for (&self.entries, 0..) |*entry, slot| {
        if (matches(entry, input)) {
            return view(entry, @intCast(slot));
        }
    }
    for (&self.wanted) |*entry| {
        if (matches(entry, input)) {
            return view(entry, 0);
        }
    }
    return null;
}

/// Protects a visible image until the current native frame has completed.
/// Example: `store.pin(request);`
pub fn pin(self: *Store, input: Request) void {
    for (&self.entries) |*entry| {
        if (matches(entry, input)) {
            entry.frame = self.frame;
            return;
        }
    }
}

/// Copies one visible request into a bounded replaceable slot. It does no I/O.
/// Example: `_ = store.request(request);`
pub fn request(self: *Store, input: Request) view_module.View {
    for (&self.entries, 0..) |*entry, slot| {
        if (matches(entry, input)) {
            entry.frame = self.frame;
            return view(entry, @intCast(slot));
        }
    }
    for (&self.wanted) |*entry| {
        if (matches(entry, input)) {
            entry.frame = self.frame;
            return view(entry, 0);
        }
    }
    if (input.text.len == 0 or !std.unicode.utf8ValidateSlice(input.text) or std.mem.indexOfScalar(u8, input.text, 0) != null) {
        return .{ .failed = .invalid };
    }
    if (input.text.len > Job.max_source_bytes or !std.math.isFinite(input.scale) or input.scale < 0.5 or input.scale > 4 or self.next_id == std.math.maxInt(u64)) {
        return .{ .failed = .limit };
    }
    if (self.available() == null) {
        return .{ .failed = .limit };
    }
    var empty: ?*Entry = null;
    for (&self.wanted) |*entry| {
        if (entry.source == null or entry.frame != self.frame) {
            empty = entry;
            break;
        }
    }
    const entry = empty orelse return .{ .failed = .limit };
    const source = self.allocator.dupe(u8, input.text) catch return .{ .failed = .limit };
    self.release(entry);
    entry.* = .{ .source = source, .kind = input.kind, .owner = input.owner, .block_offset = input.block_offset, .theme = input.theme, .scale = input.scale, .id = self.next_id, .frame = self.frame };
    self.next_id += 1;
    return .pending;
}

/// Starts at most one owned job, choosing only content requested in this frame.
/// Example: `if (store.nextJob()) |job| try service.start(job);`
pub fn nextJob(self: *Store) ?Job {
    self.admit();
    if (self.active != null) {
        return null;
    }
    for (&self.entries, 0..) |*entry, slot| {
        if (entry.source == null or entry.status != .pending or entry.frame != self.frame) {
            continue;
        }
        var job: Job = .{ .id = entry.id, .kind = entry.kind, .slot = @intCast(slot), .len = @intCast(entry.source.?.len), .theme = entry.theme, .scale = entry.scale };
        @memcpy(job.source[0..job.len], entry.source.?);
        entry.status = .running;
        self.active = entry.id;
        return job;
    }
    return null;
}

/// Exposes borrowed pixels only after preparation has finished replacing slots.
/// Example: `renderer.diagrams = store.textures();`
pub fn textures(self: *const Store) [capacity]native.DiagramTexture {
    var result: [capacity]native.DiagramTexture = @splat(.{});
    for (&self.entries, 0..) |*entry, slot| {
        if (entry.image) |image| {
            if (entry.frame != self.frame) {
                continue;
            }
            result[slot] = .{ .pixels = image.pixels.ptr, .width = image.width, .height = image.height, .version = entry.id };
        }
    }
    return result;
}

fn admit(self: *Store) void {
    for (&self.wanted) |*wanted| {
        if (wanted.source == null) {
            continue;
        }
        if (wanted.frame != self.frame) {
            self.release(wanted);
            continue;
        }
        if (wanted.status == .failed) {
            continue;
        }
        const slot = self.available() orelse {
            wanted.status = .failed;
            wanted.failure = .limit;
            self.revision +%= 1;
            continue;
        };
        self.release(&self.entries[slot]);
        self.entries[slot] = wanted.*;
        wanted.* = .{};
    }
}

/// Adopts a completed image only between native flights; stale results are freed.
/// Example: `_ = store.finish(completion);`
pub fn finish(self: *Store, completion: Completion) bool {
    if (self.active == null or self.active.? != completion.id) {
        self.discard(completion);
        return false;
    }
    self.active = null;
    self.revision +%= 1;
    for (&self.entries) |*entry| {
        if (entry.id != completion.id) {
            continue;
        }
        var image = completion.result catch |err| {
            entry.status = .failed;
            entry.failure = failure(err);
            return true;
        };
        if (!image.valid()) {
            image.deinit(self.allocator);
            entry.status = .failed;
            entry.failure = .limit;
            return true;
        }
        const pixels = @as(usize, image.width) * image.height;
        while (self.retained_pixels + pixels > max_pixels) {
            const victim = self.oldImage(entry) orelse {
                image.deinit(self.allocator);
                entry.status = .failed;
                entry.failure = .limit;
                return true;
            };
            self.release(victim);
        }
        entry.image = image;
        entry.status = .ready;
        self.retained_pixels += pixels;
        return true;
    }
    self.discard(completion);
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

fn view(entry: *const Entry, slot: u8) view_module.View {
    return switch (entry.status) {
        .pending, .running => .pending,
        .failed => .{ .failed = entry.failure },
        .ready => .{ .ready = .{ .slot = slot, .width = entry.image.?.width, .height = entry.image.?.height, .logical_width = entry.image.?.logical_width, .logical_height = entry.image.?.logical_height } },
    };
}

fn available(self: *Store) ?usize {
    var oldest: ?usize = null;
    for (&self.entries, 0..) |*entry, index| {
        if (entry.source == null) {
            return index;
        }
        if (entry.status == .running or entry.frame == self.frame) {
            continue;
        }
        if (oldest == null or entry.frame < self.entries[oldest.?].frame) {
            oldest = index;
        }
    }
    return oldest;
}

fn oldImage(self: *Store, except: *Entry) ?*Entry {
    var oldest: ?*Entry = null;
    for (&self.entries) |*entry| {
        if (entry == except or entry.image == null or entry.frame == self.frame) {
            continue;
        }
        if (oldest == null or entry.frame < oldest.?.frame) {
            oldest = entry;
        }
    }
    return oldest;
}

fn release(self: *Store, entry: *Entry) void {
    if (entry.image) |*image| {
        self.retained_pixels -= @as(usize, image.width) * image.height;
        image.deinit(self.allocator);
    }
    if (entry.source) |source| {
        self.allocator.free(source);
    }
    entry.* = .{};
}

fn discard(self: *Store, completion: Completion) void {
    var image = completion.result catch return;
    image.deinit(self.allocator);
}

fn failure(err: anyerror) view_module.Failure {
    return switch (err) {
        error.UnsupportedDiagram => .unsupported,
        error.DiagramLimit, error.OutOfMemory => .limit,
        error.RendererUnavailable => .unavailable,
        error.Timeout, error.Canceled => .timeout,
        else => .invalid,
    };
}
