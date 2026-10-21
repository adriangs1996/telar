const std = @import("std");
const Reader = @import("Reader.zig");
const Encoder = @import("Encoder.zig");

/// Copies the restorable structure with fresh shells and no agent resumes or worktree ownership.
pub fn encode(input: []const u8, output: []u8, shell: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(shell) or std.mem.indexOfScalar(u8, shell, 0) != null) {
        return error.InvalidCloneShell;
    }

    var arguments_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const arguments = try std.fmt.bufPrint(&arguments_buffer, "{s}\x00", .{shell});
    var reader = try Reader.init(input);
    var writer = try Encoder.init(output, reader.counters);

    while (try reader.next()) |record| switch (record) {
        .workspace => |workspace| try writer.workspace(workspace),
        .tab => |tab| try writer.tab(tab),
        .layout => |layout| try writer.layout(layout),
        .worktree => {},
        .pane => |pane| try writer.pane(.{
            .pane_id = pane.pane_id,
            .workspace_id = pane.workspace_id,
            .tab_id = pane.tab_id,
            .cwd = pane.cwd,
            .cols = pane.cols,
            .rows = pane.rows,
            .arguments = arguments,
            .argument_count = 1,
        }),
    };

    if (writer.dropped != 0) {
        return error.CloneTooLarge;
    }

    return writer.finish();
}
