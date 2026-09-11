//! Session checkpoint: write-behind persistence of the runtime model's
//! restorable shape and its restoration at startup.
//!
//! Persistence never runs on the interactive path. Semantic changes mark the
//! checkpoint dirty; the periodic maintenance tick snapshots the model into an
//! owned buffer and hands it to a worker that writes a temp file and renames
//! it into place. Restore runs once, before the listener accepts clients.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const checkpoint = @import("../../persistence/checkpoint.zig");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");
const client_layout_store = @import("client_layout_store.zig");

pub const Io = std.Io;
const File = Io.File;
pub const schema = core.schema;

pub const debounce_ns: u64 = 500 * std.time.ns_per_ms;
pub const snapshot_bytes = 1024 * 1024;

pub const State = @import("State.zig");

pub const OwnedWrite = @import("OwnedWrite.zig");

pub const WriteJob = @import("WriteJob.zig");

/// Writes `job.bytes()` to a temp file next to the target and renames it over
/// the previous checkpoint. Runs on a worker; never touches runtime state.
///
/// ```zig
/// try writeFile(job);
/// ```
pub fn writeFile(job: WriteJob) anyerror!void {
    const io = job.io;
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try std.fmt.bufPrint(&temp_buffer, "{s}.tmp", .{job.path});
    const file = try Io.Dir.createFileAbsolute(io, temp_path, .{
        .truncate = true,
        .permissions = File.Permissions.fromMode(0o600),
    });
    file.writeStreamingAll(io, job.bytes()) catch |err| {
        file.close(io);
        Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return err;
    };
    file.sync(io) catch |err| {
        file.close(io);
        Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return err;
    };
    file.close(io);
    Io.Dir.renameAbsolute(temp_path, job.path, io) catch |err| {
        Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return err;
    };
}

pub const Checkpointer = @import("GenericCheckpointer.zig").Type;

pub const max_resume_command_bytes = 32 + schema.max_agent_session_reference_bytes;

/// Builds the shell line that resumes a built-in agent's session, typed into
/// the restored pane's shell. Only the built-in capability table
/// (`agent.providers`) can produce a command, and only for a reference shaped
/// like a UUID, so a stored reference can never smuggle options or shell
/// syntax.
///
/// ```zig
/// const line = resumeCommand(&buffer, .claude, session) orelse return;
/// ```
pub fn resumeCommand(buffer: *[max_resume_command_bytes]u8, provider: schema.AgentProvider, session: []const u8) ?[]const u8 {
    if (!isUuid(session)) {
        return null;
    }
    const template = agent_mod.providers.of(provider).resume_prefix orelse return null;
    const len = template.len + session.len + 1;
    if (len > buffer.len) {
        return null;
    }
    @memcpy(buffer[0..template.len], template);
    @memcpy(buffer[template.len .. template.len + session.len], session);
    buffer[len - 1] = '\r';
    return buffer[0..len];
}

fn isUuid(value: []const u8) bool {
    if (value.len != 36) {
        return false;
    }
    for (value, 0..) |byte, index| {
        const dash = index == 8 or index == 13 or index == 18 or index == 23;
        if (dash) {
            if (byte != '-') {
                return false;
            }
        } else if (!std.ascii.isHex(byte)) {
            return false;
        }
    }
    return true;
}

test "resume commands exist only for built-in providers and UUID references" {
    var buffer: [max_resume_command_bytes]u8 = undefined;
    const session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";

    try std.testing.expectEqualStrings("claude --resume " ++ session ++ "\r", resumeCommand(&buffer, .claude, session).?);
    try std.testing.expectEqualStrings("codex resume " ++ session ++ "\r", resumeCommand(&buffer, .codex, session).?);
    try std.testing.expectEqualStrings("pi --session " ++ session ++ "\r", resumeCommand(&buffer, .pi, session).?);
    try std.testing.expect(resumeCommand(&buffer, @enumFromInt(schema.first_custom_agent_provider), session) == null);
    try std.testing.expect(resumeCommand(&buffer, .claude, "not-a-uuid") == null);
    try std.testing.expect(resumeCommand(&buffer, .claude, "0192aaaa-bbbb-cccc-dddd-eeeeffff000g") == null);
}

test "checkpoint state debounces, coalesces and retries after failure" {
    var state: State = .{ .path = "/tmp/session.ckpt" };
    try std.testing.expect(!state.due(0));

    state.noteChange(1_000);
    try std.testing.expect(!state.due(1_000 + debounce_ns - 1));
    try std.testing.expect(state.due(1_000 + debounce_ns));

    var scheduler: TestingScheduler = .{};
    try state.startWrite(try testingWrite(), &scheduler);
    try std.testing.expect(!state.due(std.math.maxInt(u64)));
    state.noteChange(2_000);
    state.completeWrite({});
    try std.testing.expect(state.dirty);
    try std.testing.expectEqual(@as(u64, 1), state.writes);

    try state.startWrite(try testingWrite(), &scheduler);
    state.completeWrite(error.DiskFull);
    try std.testing.expect(state.dirty);
    try std.testing.expectEqual(@as(u64, 1), state.failures);
    try std.testing.expect(state.due(2_000 + debounce_ns));

    var disabled: State = .{};
    disabled.noteChange(5);
    try std.testing.expect(!disabled.dirty);
}

const TestingScheduler = @import("TestingScheduler.zig");

fn testingWrite() !OwnedWrite {
    return .{
        .allocator = std.testing.allocator,
        .job = .{ .io = std.testing.io, .path = "/unused", .buffer = try std.testing.allocator.alloc(u8, 1), .len = 1 },
    };
}

test "checkpoint startup failure releases ownership once and permits retry" {
    var state: State = .{ .path = "/unused", .dirty = true };
    var scheduler: TestingScheduler = .{ .fail = true };
    try std.testing.expectError(error.SchedulerUnavailable, state.startWrite(try testingWrite(), &scheduler));
    try std.testing.expect(state.pending == null);
    try std.testing.expect(state.dirty);
    try std.testing.expectEqual(@as(u64, 1), state.failures);
    state.completeWrite(error.SchedulerUnavailable);
    try std.testing.expectEqual(@as(u64, 1), state.failures);

    scheduler.fail = false;
    try state.startWrite(try testingWrite(), &scheduler);
    state.completeWrite({});
    try std.testing.expect(!state.dirty);
    try std.testing.expectEqual(@as(u64, 1), state.writes);
}

test "writeFile replaces the checkpoint atomically and keeps it private" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/session.ckpt", .{root});
    var payload = "first".*;

    try writeFile(.{ .io = std.testing.io, .path = path, .buffer = &payload, .len = payload.len });
    var second = "second!".*;
    try writeFile(.{ .io = std.testing.io, .path = path, .buffer = &second, .len = second.len });

    const written = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("second!", written);
    const stat = try Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}
