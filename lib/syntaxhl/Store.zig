//! Bounded content cache. Source bytes, not theme or addresses, identify a job.
const Role = @import("role.zig").Role;
const std = @import("std");
const Entry = @import("Entry.zig");
const Job = @import("Job.zig");
const Result = @import("Result.zig");
const limits = @import("limits.zig");
const Self = @This();

entries: [limits.cache_entries]Entry = @splat(.{}),
frame: u64 = 1,
next_id: u64 = 1,

pub fn beginFrame(self: *Self) void {
    self.frame +%= 1;
    if (self.frame == 0) {
        for (&self.entries) |*entry| {
            entry.frame = 0;
        }
        self.frame = 1;
    }
}

/// Frame preparation copies bounded source; it never calls the parser or allocates.
/// Returned roles remain borrowed only for synchronous painting.
/// Example: `const roles = store.request(diff);`
pub fn request(self: *Self, text: []const u8) ?[]const Role {
    if (text.len == 0 or text.len > limits.source_bytes or self.next_id == std.math.maxInt(u64)) {
        return null;
    }

    const hash = std.hash.Wyhash.hash(0, text);
    var candidate: ?*Entry = null;
    for (&self.entries) |*entry| {
        if (entry.status != .empty and entry.len == text.len and entry.hash == hash and std.mem.eql(u8, entry.source[0..entry.len], text)) {
            entry.frame = self.frame;
            return if (entry.status == .ready) entry.roles[0..entry.len] else null;
        }

        if (entry.status == .empty or entry.frame != self.frame) {
            if (candidate == null or entry.status == .empty or entry.frame < candidate.?.frame) {
                candidate = entry;
            }
        }
    }

    const entry = candidate orelse return null;
    @memcpy(entry.source[0..text.len], text);
    entry.len = text.len;
    entry.hash = hash;
    entry.id = self.next_id;
    self.next_id += 1;
    entry.frame = self.frame;
    entry.status = .pending;
    return null;
}

/// Copies an owned request; later slot replacement cannot mutate worker input.
/// Example: `if (store.nextJob()) |job| start(job);`
pub fn nextJob(self: *Self) ?Job {
    for (&self.entries) |*entry| {
        if (entry.status == .pending and entry.frame == self.frame) {
            var job: Job = .{ .len = entry.len, .id = entry.id };
            @memcpy(job.source[0..job.len], entry.source[0..entry.len]);
            entry.status = .running;
            return job;
        }
    }

    return null;
}

/// Stale completions never recolor replacement content.
/// Example: `store.finish(&result);`
pub fn finish(self: *Self, result: *const Result) void {
    for (&self.entries) |*entry| {
        if (entry.id != result.id or entry.status != .running) {
            continue;
        }

        if (result.status) |_| {
            @memcpy(entry.roles[0..entry.len], result.roles[0..entry.len]);
            entry.status = .ready;
        } else |_| {
            entry.status = .failed;
        }
        return;
    }
}
