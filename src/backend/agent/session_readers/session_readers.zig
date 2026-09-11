//! Provider-specific reads of session files on the observation worker.

const Job = @import("Job.zig");
const Completion = @import("../Completion.zig");
const claude = @import("claude.zig");
const codex = @import("codex.zig");
const std = @import("std");
const TestDirectory = @import("TestDirectory.zig");
const SessionReferenceType = @import("../SessionReference.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

/// Runs on a worker: never touches runtime state.
///
/// ```zig
/// const completion = probe(job);
/// ```
pub fn probe(job: Job) Completion {
    var completion: Completion = .{ .key = job.watch.key, .offset = job.watch.offset };
    switch (job.watch.kind) {
        .claude_transcript => claude.probe(job, &completion),
        .codex_state => codex.probe(job, &completion),
    }

    return completion;
}

test "transcript probe seeds at the end, then reads only appended lines and resumes after a rewrite" {
    const io = std.testing.io;
    var directory = try TestDirectory.init(io);
    defer directory.deinit();
    var watch = try directory.watch(.claude_transcript, "session.jsonl");

    const old_line = "{\"type\":\"custom-title\",\"customTitle\":\"old\",\"sessionId\":\"abc\"}\n";
    const new_line = "{\"type\":\"custom-title\",\"customTitle\":\"Fix proxy\",\"sessionId\":\"abc\"}\n";
    try directory.temp.dir.writeFile(io, .{ .sub_path = "session.jsonl", .data = old_line });
    const seeded = probe(.{ .io = io, .watch = watch });
    try std.testing.expect(!seeded.has_title);
    try std.testing.expectEqual(@as(?u64, old_line.len), seeded.offset);

    watch.offset = seeded.offset;
    const appended = try directory.temp.dir.openFile(io, "session.jsonl", .{ .mode = .write_only });
    defer appended.close(io);
    var writer = appended.writerStreaming(io, &.{});
    try writer.seekTo(old_line.len);
    try writer.interface.writeAll(new_line ++ "{\"type\":\"user\"");
    try writer.interface.flush();
    const named = probe(.{ .io = io, .watch = watch });
    try std.testing.expect(named.has_title);
    try std.testing.expectEqualStrings("Fix proxy", named.titleSlice());
    try std.testing.expectEqual(@as(?u64, old_line.len + new_line.len), named.offset);

    watch.offset = named.offset;
    const idle = probe(.{ .io = io, .watch = watch });
    try std.testing.expect(!idle.has_title);
    try std.testing.expectEqual(named.offset, idle.offset);

    watch.offset = 10_000;
    const rewritten = probe(.{ .io = io, .watch = watch });
    try std.testing.expectEqualStrings("Fix proxy", rewritten.titleSlice());

    watch.path_len -= 1;
    const missing = probe(.{ .io = io, .watch = watch });
    try std.testing.expect(!missing.has_title);
    try std.testing.expectEqual(@as(?u64, 10_000), missing.offset);
}

test "a transcript that does not exist yet is read whole once it appears" {
    const io = std.testing.io;
    var directory = try TestDirectory.init(io);
    defer directory.deinit();
    var watch = try directory.watch(.claude_transcript, "later.jsonl");

    const unborn = probe(.{ .io = io, .watch = watch });
    try std.testing.expect(!unborn.has_title);
    try std.testing.expectEqual(@as(?u64, 0), unborn.offset);

    watch.offset = unborn.offset;
    try directory.temp.dir.writeFile(io, .{ .sub_path = "later.jsonl", .data = "{\"type\":\"custom-title\",\"customTitle\":\"tiempo-valencia\",\"sessionId\":\"abc\"}\n" });
    const born = probe(.{ .io = io, .watch = watch });
    try std.testing.expect(born.has_title);
    try std.testing.expectEqualStrings("tiempo-valencia", born.titleSlice());
}

test "codex state probe reads the thread name, a NULL name as empty and nothing for unknown threads" {
    const io = std.testing.io;
    var directory = try TestDirectory.init(io);
    defer directory.deinit();
    const watch = try directory.watch(.codex_state, "state_5.sqlite");

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}", .{watch.pathSlice()});
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    const opened = db.?;
    const setup =
        "CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', name TEXT);" ++
        "INSERT INTO threads(id, name) VALUES('abc', 'Fix proxy'), ('unnamed', NULL);";
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_exec(opened, setup, null, null, null));
    _ = c.sqlite3_close(opened);

    const named = probe(.{ .io = io, .watch = watch });
    try std.testing.expect(named.has_title);
    try std.testing.expectEqualStrings("Fix proxy", named.titleSlice());
    try std.testing.expect(named.offset == null);

    var unnamed = watch;
    unnamed.session = try SessionReferenceType.init("unnamed", 1);
    const cleared = probe(.{ .io = io, .watch = unnamed });
    try std.testing.expect(cleared.has_title);
    try std.testing.expectEqualStrings("", cleared.titleSlice());

    var unknown = watch;
    unknown.session = try SessionReferenceType.init("nope", 1);
    try std.testing.expect(!probe(.{ .io = io, .watch = unknown }).has_title);

    var missing = watch;
    missing.path_len -= 1;
    try std.testing.expect(!probe(.{ .io = io, .watch = missing }).has_title);
}
