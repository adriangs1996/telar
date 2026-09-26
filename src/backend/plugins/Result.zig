const core = @import("telar-core");
const std = @import("std");
const Batch = @import("Batch.zig");
const Result = @This();

gpa: std.mem.Allocator,
package_index: u8,
plugin_id: u64,
digest: core.Digest,
generation: u64,
event_id: u64,
storage: []u8,
batch: Batch,

/// Erases and releases the worker frame and result allocation.
///
/// ```zig
/// result.deinit();
/// ```
pub fn deinit(self: *Result) void {
    const gpa = self.gpa;
    std.crypto.secureZero(u8, self.storage);
    gpa.free(self.storage);
    std.crypto.secureZero(u8, std.mem.asBytes(self));
    gpa.destroy(self);
}
