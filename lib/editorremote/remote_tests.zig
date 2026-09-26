const std = @import("std");
const Search = @import("Search.zig");
const Candidate = @import("Candidate.zig");
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
    var candidates = [_]Candidate{.{ .process_group = pid + 1 }};
    var search: Search = .{
        .editor = "nvim",
        .path = path,
        .candidates = &candidates,
        .environment = inherited,
    };
    try std.testing.expectEqual(@as(?usize, null), try search.run(io));
    const modified = try search.command(&.{ "nvim", "--server", socket, "--remote-expr", "setline(1, 'unsaved work')" });
    defer Search.release(modified);
    candidates[0].process_group = pid;
    search = .{
        .editor = "nvim",
        .path = path,
        .candidates = &candidates,
        .environment = inherited,
    };
    try std.testing.expectEqual(@as(?usize, 0), try search.run(io));
    const output = try search.command(&.{ "nvim", "--server", socket, "--remote-expr", "expand('%:p')" });
    defer Search.release(output);
    try std.testing.expectEqualStrings(path, std.mem.trimEnd(u8, output.stdout, "\r\n"));

    const preserved = try search.command(&.{ "nvim", "--server", socket, "--remote-expr", "getbufline(1, 1)[0]" });
    defer Search.release(preserved);
    try std.testing.expectEqualStrings("unsaved work", std.mem.trimEnd(u8, preserved.stdout, "\r\n"));

    try temp.dir.writeFile(
        io,
        .{
            .sub_path = "positioned.zig",
            .data = "one\ntwo\nthree\n    four\nfive\n",
        },
    );
    var positioned_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const positioned = try std.fmt.bufPrint(&positioned_buffer, "{s}/positioned.zig", .{directory});
    search = .{
        .editor = "nvim",
        .path = positioned,
        .line = 4,
        .column = 6,
        .candidates = &candidates,
        .environment = inherited,
    };
    try std.testing.expectEqual(@as(?usize, 0), try search.run(io));
    const cursor = try search.command(&.{ "nvim", "--server", socket, "--remote-expr", "line('.') . ':' . col('.')" });
    defer Search.release(cursor);
    try std.testing.expectEqualStrings("4:6", std.mem.trimEnd(u8, cursor.stdout, "\r\n"));

    var expression_buffer: [expressions.max_bytes]u8 = undefined;
    const stale = try expressions.vim(&expression_buffer, .{ .pid = pid + 1, .path = "/tmp/should-not-open" });
    const refused = try search.command(&.{ "nvim", "--server", socket, "--remote-expr", stale });
    defer Search.release(refused);
    try std.testing.expectEqualStrings("0", std.mem.trim(u8, refused.stdout, "\r\n"));
}

test "a Neovim server whose parent is the pane's foreground process opens in that pane" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var socket_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const socket = try std.fmt.bufPrint(&socket_buffer, "{s}/nvim.server.0", .{directory});
    // The test process plays the TUI: the server is its child, like `nvim --embed`.
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
    var ready = false;
    for (0..100) |_| {
        if (temp.dir.statFile(io, "nvim.server.0", .{})) |_| {
            ready = true;
            break;
        } else |_| {}

        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }

    try std.testing.expect(ready);
    try temp.dir.writeFile(
        io,
        .{
            .sub_path = "split.zig",
            .data = "one\ntwo\nthree\n",
        },
    );
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    try environment.put("XDG_RUNTIME_DIR", directory);
    const inherited: std.process.Environ = .{ .block = try environment.createPosixBlock(gpa, .{}) };
    defer inherited.block.deinit(gpa);
    var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&file_buffer, "{s}/split.zig", .{directory});
    var candidates = [_]Candidate{.{ .process_group = @intCast(std.c.getpid()) }};
    var search: Search = .{
        .editor = "nvim",
        .path = path,
        .line = 2,
        .candidates = &candidates,
        .environment = inherited,
    };
    try std.testing.expectEqual(@as(?usize, 0), try search.run(io));
    const cursor = try search.command(&.{ "nvim", "--server", socket, "--remote-expr", "expand('%:t') . ':' . line('.')" });
    defer Search.release(cursor);
    try std.testing.expectEqualStrings("split.zig:2", std.mem.trimEnd(u8, cursor.stdout, "\r\n"));
}

test "a search without candidates does no discovery" {
    var search: Search = .{
        .editor = "nvim",
        .path = "/tmp/file",
        .candidates = &.{},
        .environment = std.testing.environ,
    };
    try std.testing.expectEqual(@as(?usize, null), try search.run(std.testing.io));
    try std.testing.expectEqual(Search.max_entries, search.commands_left);
}
