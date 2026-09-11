const std = @import("std");
const DigestType = @import("telar-core").Digest;
const PaneIdType = @import("telar-core").PaneId;
const Batch = @import("Batch.zig");
const Result = @This();

gpa: std.mem.Allocator,
package_index: u8,
plugin_id: u64,
digest: DigestType,
generation: u64,
event_id: u64,
pane: PaneIdType,
pane_generation: u64,
storage: []u8,
batch: Batch,

/// Erases and releases the worker frame and result allocation.
///
/// ```zig
/// result.deinit();
/// ```
pub fn deinit(result: *Result) void {
    const gpa = result.gpa;
    std.crypto.secureZero(u8, result.storage);
    gpa.free(result.storage);
    std.crypto.secureZero(u8, std.mem.asBytes(result));
    gpa.destroy(result);
}
