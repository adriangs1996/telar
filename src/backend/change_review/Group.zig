const Edition = @import("Edition.zig");
const Sample = @import("Sample.zig");
const Context = @import("Context.zig");
const ArchiveRecord = @import("ArchiveRecord.zig");
const std = @import("std");

pub const capacity = 16;
pub const archive_capacity = 4096;
pub const sample_capacity = 32;
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
            gpa.destroy(value);
        }
    }
}
