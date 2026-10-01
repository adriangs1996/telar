const core = @import("telar-core");
const Edition = @import("Edition.zig");
const Sample = @import("Sample.zig");
const Context = @import("Context.zig");
const ArchiveRecord = @import("ArchiveRecord.zig");
const std = @import("std");

pub const capacity = 16;
pub const archive_capacity = 4096;
/// Before-samples one conversation may hold while their tools run; a hook
/// samples at most `ReviewHookFiles.capacity` files per tool call.
pub const sample_capacity = 128;

pub const editions_limit = core.Limit.declare("review.editions_in_memory", "editions with unsent comments", capacity);
pub const archive_limit = core.Limit.declare("review.archive_capacity", "editions", archive_capacity);
pub const samples_limit = core.Limit.declare("review.pending_samples", "pending samples", sample_capacity);

key: [64]u8,
context: Context,
editions: [capacity]?*Edition = @splat(null),
count: u8 = 0,
records: [archive_capacity]ArchiveRecord = undefined,
total: u16 = 0,
samples: [sample_capacity]?*Sample = @splat(null),

/// Counts the bytes retained outside the manifest. Example: `const bytes = group.archivedBytes();`
pub fn archivedBytes(self: *const @This()) usize {
    var bytes: usize = 0;
    for (self.records[0..self.total]) |record| {
        bytes += record.bytes;
    }

    return bytes;
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    for (self.editions[0..self.count]) |edition| {
        gpa.destroy(edition.?);
    }

    for (self.samples) |sample| {
        if (sample) |value| {
            value.destroy(gpa);
        }
    }
}
