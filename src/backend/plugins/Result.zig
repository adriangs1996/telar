const Result = @This();
const std = @import("std");
const core = @import("telar-core");
const Batch = @import("Batch.zig");
gpa: std.mem.Allocator,
package_index: u8,
plugin_id: u64,
digest: core.plugin.Digest,
generation: u64,
event_id: u64,
pane: core.schema.PaneId,
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
