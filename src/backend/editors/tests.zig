const std = @import("std");
const core = @import("telar-core");
const Job = @import("Job.zig");
const expressions = @import("expressions.zig");

test "editor discovery opens literal paths in the matching real Neovim process" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var socket_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const socket = try std.fmt.bufPrint(&socket_buffer, "{s}/nvim.test.0", .{directory});
    var child = std.process.spawn(io, .{
        .argv = &.{ "nvim", "--headless", "-u", "NONE", "-i", "NONE", "-n", "--listen", socket },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer child.kill(io);
    const pid: u32 = @intCast(child.id.?);
    var ready = false;
    for (0..100) |_| {
        if (temp.dir.statFile(io, "nvim.test.0", .{})) |_| {
            ready = true;
            break;
        } else |_| {}

        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }

    try std.testing.expect(ready);
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    try environment.put("XDG_RUNTIME_DIR", directory);
    const inherited: std.process.Environ = .{ .block = try environment.createPosixBlock(gpa, .{}) };
    defer inherited.block.deinit(gpa);
    var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&file_buffer, "{s}/a b'|quit!\"\\$().txt", .{directory});
    var request: core.OwnedEditorOpen = .{ .request_id = @enumFromInt(1), .pane_id = @enumFromInt(10), .pane_generation = 7 };
    try request.setTarget("nvim", path);
    var job: Job = .{
        .client = .{ .id = 1, .generation = 1 },
        .request = request,
        .environment = inherited,
        .result = .{ .request_id = request.request_id, .outcome = .unavailable },
        .candidate_count = 1,
    };
    job.candidates[0] = .{ .pane = .{ .id = @enumFromInt(20), .generation = 9 }, .process_group = pid + 1 };
    _ = Job.run(&job, io);
    try std.testing.expectEqual(core.EditorOpened.Outcome.unavailable, job.result.outcome);
    const modified = try job.command(&.{ "nvim", "--server", socket, "--remote-expr", "setline(1, 'unsaved work')" });
    defer Job.release(modified);
    job.candidates[0].process_group = pid;
    _ = Job.run(&job, io);
    try std.testing.expectEqual(core.EditorOpened.Outcome.opened, job.result.outcome);
    try std.testing.expectEqual(job.candidates[0].pane.id, job.result.pane_id);
    try std.testing.expectEqual(@as(u64, 9), job.result.pane_generation);
    const output = try job.command(&.{ "nvim", "--server", socket, "--remote-expr", "expand('%:p')" });
    defer Job.release(output);
    try std.testing.expectEqualStrings(path, std.mem.trimEnd(u8, output.stdout, "\r\n"));

    const preserved = try job.command(&.{ "nvim", "--server", socket, "--remote-expr", "getbufline(1, 1)[0]" });
    defer Job.release(preserved);
    try std.testing.expectEqualStrings("unsaved work", std.mem.trimEnd(u8, preserved.stdout, "\r\n"));

    var expression_buffer: [expressions.max_bytes]u8 = undefined;
    const stale = try expressions.vim(&expression_buffer, .{ .pid = pid + 1, .path = "/tmp/should-not-open" });
    const refused = try job.command(&.{ "nvim", "--server", socket, "--remote-expr", stale });
    defer Job.release(refused);
    try std.testing.expectEqualStrings("0", std.mem.trim(u8, refused.stdout, "\r\n"));
}

test "editor workers do no discovery without a matching tab candidate" {
    var request: core.OwnedEditorOpen = .{ .request_id = @enumFromInt(1), .pane_id = @enumFromInt(2), .pane_generation = 3 };
    try request.setTarget("nvim", "/tmp/file");
    var job: Job = .{
        .client = .{ .id = 1, .generation = 1 },
        .request = request,
        .environment = std.testing.environ,
        .result = .{ .request_id = request.request_id, .outcome = .unavailable },
    };
    _ = Job.run(&job, std.testing.io);
    try std.testing.expectEqual(core.EditorOpened.Outcome.unavailable, job.result.outcome);
    try std.testing.expectEqual(Job.max_entries, job.commands_left);
}
