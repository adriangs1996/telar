const std = @import("std");
const core = @import("telar-core");

gpa: std.mem.Allocator,
value: *core.AgentHistoryPage,

/// Releases the page after delivery, cancellation or stale-client rejection.
/// Example: `page.deinit();`.
pub fn deinit(page: *@This()) void {
    const gpa = page.gpa;
    gpa.destroy(page.value);
    gpa.destroy(page);
}
