//! Session names read from the files agents record their sessions in.
//!
//! Claude Code writes `/rename` to its transcript and Codex to its state
//! database, and neither tells a hook, so the runtime polls the file the
//! hooks point at. Probing runs on the observation path: the maintenance tick
//! starts at most one bounded worker for the stalest due watch, the worker
//! reads what changed, and the completion hands the name to the agent
//! tracker like a hook-reported title.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const Io = std.Io;
const schema = core.schema;
const session_file = agent_mod.session_file;
const transcript = agent_mod.transcript;

pub const probe_interval_ms: i64 = 1_000;
pub const Completion = session_file.Completion;
const thread_name_sql = "SELECT name FROM threads WHERE id = ?1";

pub const Job = struct {
    io: Io,
    watch: session_file.Watch,
};

/// Runs on a worker: never touches runtime state.
///
/// ```zig
/// const completion = probe(job);
/// ```
pub fn probe(job: Job) Completion {
    var completion: Completion = .{ .key = job.watch.key, .offset = job.watch.offset };
    switch (job.watch.kind) {
        .claude_transcript => probeTranscript(job, &completion),
        .codex_state => probeCodexState(job, &completion),
    }

    return completion;
}

/// The first probe of a watch only records where the file ends; later
/// probes read at most `max_scan_bytes` past the last offset and leave the
/// rest for the next one. Claude Code creates the transcript lazily, so a
/// file that does not exist yet is seeded at zero and read whole once it
/// appears. A file shorter than the offset was rewritten and is read again.
fn probeTranscript(job: Job, completion: *Completion) void {
    const file = Io.Dir.cwd().openFile(job.io, job.watch.pathSlice(), .{}) catch {
        if (job.watch.offset == null) {
            completion.offset = 0;
        }

        return;
    };
    defer file.close(job.io);
    const length = file.length(job.io) catch return;
    const start = job.watch.offset orelse {
        completion.offset = length;
        return;
    };
    const offset = if (length < start) 0 else start;
    if (length == offset) {
        completion.offset = offset;
        return;
    }

    const gpa = std.heap.page_allocator;
    const buffer = gpa.alloc(u8, transcript.max_scan_bytes) catch return;
    defer gpa.free(buffer);
    var reader = file.reader(job.io, &.{});
    reader.seekTo(offset) catch return;
    const len = reader.interface.readSliceShort(buffer) catch return;

    var title_buffer: [schema.max_agent_session_title_bytes]u8 = undefined;
    const result = transcript.scan(buffer[0..len], job.watch.session.slice(), &title_buffer);
    // A line longer than the whole window can never complete: skip it.
    const consumed = if (result.consumed == 0 and len == buffer.len) len else result.consumed;
    completion.offset = offset + consumed;
    if (result.title) |title| {
        completion.setTitle(title);
    }
}

/// Reads the thread's current name with a read-only connection. Codex keeps
/// the database in WAL mode, so a reader never blocks its writer; a busy or
/// missing database, or a thread not yet inserted, reports nothing. A NULL
/// name reports an empty title, which clears an earlier agent title.
fn probeCodexState(job: Job, completion: *Completion) void {
    var path_buffer: [session_file.max_path_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "{s}", .{job.watch.pathSlice()}) catch return;
    var db: ?*c.sqlite3 = null;
    const opened = if (c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX, null) == c.SQLITE_OK) db else null;
    defer if (db) |handle| {
        _ = c.sqlite3_close(handle);
    };
    const connection = opened orelse return;
    _ = c.sqlite3_busy_timeout(connection, 200);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(connection, thread_name_sql, thread_name_sql.len, &stmt, null) != c.SQLITE_OK) {
        return;
    }
    const statement = stmt orelse return;
    defer _ = c.sqlite3_finalize(statement);
    const session = job.watch.session.slice();
    if (c.sqlite3_bind_text(statement, 1, session.ptr, @intCast(session.len), null) != c.SQLITE_OK) {
        return;
    }
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) {
        return;
    }

    var title_buffer: [schema.max_agent_session_title_bytes]u8 = undefined;
    const name = columnText(statement, 0);
    completion.setTitle(schema.truncateSessionTitle(&title_buffer, name));
}

fn columnText(statement: *c.sqlite3_stmt, column: c_int) []const u8 {
    if (c.sqlite3_column_type(statement, column) == c.SQLITE_NULL) {
        return "";
    }

    const pointer = c.sqlite3_column_text(statement, column) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(statement, column));
    return pointer[0..len];
}

/// Binds probing to one application type providing `io`, `select`,
/// `model.agents`, `session_name_probe_in_flight`, `noteSessionChange` and
/// `pumpAll`.
pub fn Observer(comptime Application: type) type {
    return struct {
        /// Starts one probe for the stalest due session file, if any.
        ///
        /// ```zig
        /// SessionNameObserver.tick(&application);
        /// ```
        pub fn tick(application: *Application) void {
            if (application.session_name_probe_in_flight) {
                return;
            }

            const now_ms = Io.Timestamp.now(application.io, .real).toMilliseconds();
            const watch = application.model.agents.nextSessionFileProbe(now_ms, probe_interval_ms) orelse return;

            application.session_name_probe_in_flight = true;
            application.select.concurrent(.session_name, probe, .{Job{ .io = application.io, .watch = watch }}) catch {
                application.session_name_probe_in_flight = false;
                _ = application.model.agents.finishSessionFileProbe(.{ .key = watch.key, .offset = watch.offset }, now_ms);
            };
        }

        /// Applies one probe result and publishes a changed title.
        ///
        /// ```zig
        /// SessionNameObserver.handleCompletion(&application, completion);
        /// ```
        pub fn handleCompletion(application: *Application, completion: Completion) void {
            application.session_name_probe_in_flight = false;
            const now_ms = Io.Timestamp.now(application.io, .real).toMilliseconds();

            if (application.model.agents.finishSessionFileProbe(completion, now_ms)) {
                application.noteSessionChange();
                application.pumpAll();
            }
        }
    };
}

const TestDirectory = struct {
    temp: std.testing.TmpDir,
    buffer: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn init(io: Io) !TestDirectory {
        var directory: TestDirectory = .{ .temp = std.testing.tmpDir(.{}) };
        directory.len = try directory.temp.dir.realPath(io, &directory.buffer);
        return directory;
    }

    fn deinit(directory: *TestDirectory) void {
        directory.temp.cleanup();
    }

    fn watch(directory: *const TestDirectory, kind: session_file.Kind, name: []const u8) !session_file.Watch {
        var value: session_file.Watch = .{
            .key = .{ .id = try schema.id.pane(7), .generation = 3 },
            .session = try agent_mod.SessionReference.init("abc", 1),
            .kind = kind,
        };
        const path = try std.fmt.bufPrint(&value.path, "{s}/{s}", .{ directory.buffer[0..directory.len], name });
        value.path_len = @intCast(path.len);
        return value;
    }
};

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
    unnamed.session = try agent_mod.SessionReference.init("unnamed", 1);
    const cleared = probe(.{ .io = io, .watch = unnamed });
    try std.testing.expect(cleared.has_title);
    try std.testing.expectEqualStrings("", cleared.titleSlice());

    var unknown = watch;
    unknown.session = try agent_mod.SessionReference.init("nope", 1);
    try std.testing.expect(!probe(.{ .io = io, .watch = unknown }).has_title);

    var missing = watch;
    missing.path_len -= 1;
    try std.testing.expect(!probe(.{ .io = io, .watch = missing }).has_title);
}
