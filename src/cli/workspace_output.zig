const std = @import("std");
const core = @import("telar-core");

/// Writes one borrowed workspace without exposing wire storage. Example: `try workspace_output.write(writer, entry, true);`
pub fn write(writer: *std.Io.Writer, entry: core.WorkspaceListEntry, json: bool) !void {
    if (json) {
        try std.json.Stringify.value(.{ .workspace_id = core.raw(entry.workspace), .name = entry.name, .path = entry.path, .tab_count = entry.tab_count, .branch = entry.branch, .dirty = entry.dirty }, .{}, writer);
    } else {
        try writer.print("{d}\t{s}\t{s}\t{d}\t{s}\t{s}\n", .{ core.raw(entry.workspace), entry.name, entry.path, entry.tab_count, entry.branch, if (entry.dirty) "dirty" else "clean" });
    }
}
