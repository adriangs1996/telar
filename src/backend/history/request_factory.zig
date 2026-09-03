//! Construction of owned messages accepted by the history channel.

const std = @import("std");
const model = @import("model.zig");
const terminal = @import("terminal.zig");

pub const LaunchAttemptRequest = struct {
    pane_id: model.schema.PaneId,
    pane_generation: u64,
    location: model.schema.TabLocation,
    workspace_path: []const u8,
    shell: []const u8,
    started_at_ms: i64,
    phase: model.LaunchPhase,
    cause: []const u8,
};

pub const SessionStartRequest = struct {
    session_id: model.SessionId,
    pane_id: model.schema.PaneId,
    location: model.schema.TabLocation,
    workspace_path: []const u8,
    shell: []const u8,
    started_at_ms: i64,
};

pub const CommandContext = struct {
    author: model.schema.HistoryAuthor = .human,
    origin: model.schema.HistoryOrigin = .pane,
    session_id: model.SessionId,
    pane_id: model.schema.PaneId,
    location: model.schema.TabLocation,
    sequence: u64,
    workspace_path: []const u8,
    cols: u16,
    rows: u16,
    provider: []const u8 = "",
    tool_call_id: []const u8 = "",
};

pub const CommandRecord = struct {
    context: CommandContext,
    command: terminal.Command,
};

/// Copies a failed launch into one request whose ownership can cross the
/// history channel. Partial allocation failure releases every prior copy.
///
/// ```zig
/// const request = try launchAttempt(gpa, io, input);
/// ```
pub fn launchAttempt(gpa: std.mem.Allocator, io: std.Io, input: LaunchAttemptRequest) !model.Request {
    const value = try gpa.create(model.LaunchAttempt);
    errdefer gpa.destroy(value);

    const workspace_path = try gpa.dupe(u8, input.workspace_path);
    errdefer gpa.free(workspace_path);

    const shell = try gpa.dupe(u8, input.shell);
    errdefer gpa.free(shell);

    const cause = try gpa.dupe(u8, input.cause);
    errdefer gpa.free(cause);

    value.* = .{
        .pane_id = input.pane_id,
        .pane_generation = input.pane_generation,
        .location = input.location,
        .started_at_ms = input.started_at_ms,
        .failed_at_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .phase = input.phase,
        .workspace_path = workspace_path,
        .shell = shell,
        .cause = cause,
    };

    return .{ .launch_attempt = value };
}

/// Copies a committed pane session into one request owned by the history
/// channel.
///
/// ```zig
/// const request = try sessionStarted(gpa, input);
/// ```
pub fn sessionStarted(gpa: std.mem.Allocator, input: SessionStartRequest) !model.Request {
    const value = try gpa.create(model.SessionStarted);
    errdefer gpa.destroy(value);

    const workspace_path = try gpa.dupe(u8, input.workspace_path);
    errdefer gpa.free(workspace_path);

    const shell = try gpa.dupe(u8, input.shell);
    errdefer gpa.free(shell);

    value.* = .{
        .id = input.session_id,
        .pane_id = input.pane_id,
        .location = input.location,
        .started_at_ms = input.started_at_ms,
        .workspace_path = workspace_path,
        .shell = shell,
    };

    return .{ .session_started = value };
}

/// Validates and copies a bounded session title into a channel request.
///
/// ```zig
/// const request = try sessionTitle(definition);
/// ```
pub fn sessionTitle(definition: model.SessionTitle.Definition) !model.Request {
    return .{ .session_title = try model.SessionTitle.init(definition) };
}

/// Copies one decoded wire batch before its borrowed transport buffer is
/// released.
///
/// ```zig
/// const request = try importBatch(gpa, view);
/// ```
pub fn importBatch(gpa: std.mem.Allocator, view: model.schema.ImportHistoryView) !model.Request {
    return .{ .import = try model.ImportBatch.init(gpa, view) };
}

/// Copies a completed command and every borrowed byte slice into one aligned
/// allocation. Destroying the resulting request releases the whole record.
///
/// ```zig
/// const request = try commandFinished(gpa, record);
/// ```
pub fn commandFinished(gpa: std.mem.Allocator, record: CommandRecord) !model.Request {
    const context = record.context;
    const command = record.command;
    const allocation_len = @sizeOf(model.CommandFinished) + command.bytes.len +
        command.cwd.len + context.workspace_path.len + context.provider.len +
        context.tool_call_id.len + command.output.len;
    const allocation = try gpa.alignedAlloc(u8, .of(model.CommandFinished), allocation_len);
    const value: *model.CommandFinished = @ptrCast(allocation);
    var cursor: usize = @sizeOf(model.CommandFinished);

    const command_copy = allocation[cursor..][0..command.bytes.len];
    cursor += command_copy.len;
    const cwd_copy = allocation[cursor..][0..command.cwd.len];
    cursor += cwd_copy.len;
    const workspace_copy = allocation[cursor..][0..context.workspace_path.len];
    cursor += workspace_copy.len;
    const provider_copy = allocation[cursor..][0..context.provider.len];
    cursor += provider_copy.len;
    const tool_call_id_copy = allocation[cursor..][0..context.tool_call_id.len];
    cursor += tool_call_id_copy.len;
    const output_copy = allocation[cursor..][0..command.output.len];

    @memcpy(command_copy, command.bytes);
    @memcpy(cwd_copy, command.cwd);
    @memcpy(workspace_copy, context.workspace_path);
    @memcpy(provider_copy, context.provider);
    @memcpy(tool_call_id_copy, context.tool_call_id);
    @memcpy(output_copy, command.output);

    value.* = .{
        .session_id = context.session_id,
        .pane_id = context.pane_id,
        .location = context.location,
        .sequence = context.sequence,
        .started_at_ms = command.started_at_ms,
        .duration_ns = command.duration_ns,
        .exit_code = command.exit_code,
        .status = switch (command.status) {
            .completed => .completed,
            .interrupted => .interrupted,
        },
        .author = context.author,
        .origin = context.origin,
        .cols = context.cols,
        .rows = context.rows,
        .command = command_copy,
        .cwd = cwd_copy,
        .workspace_path = workspace_copy,
        .provider = provider_copy,
        .tool_call_id = tool_call_id_copy,
        .command_truncated = command.truncated,
        .output = output_copy,
        .output_truncated = command.output_truncated,
        .output_observed = command.output_observed,
    };

    return .{ .command_finished = value };
}

const test_location: model.schema.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(2) },
    .tab_id = @enumFromInt(5),
};

fn buildLaunchAttempt(gpa: std.mem.Allocator) !void {
    const request = try launchAttempt(gpa, std.testing.io, .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 3,
        .location = test_location,
        .workspace_path = "/work/telar",
        .shell = "/bin/sh",
        .started_at_ms = 1_000,
        .phase = .output_actor,
        .cause = "InjectedLaunchFailure",
    });
    defer model.deinitRequest(request, gpa);
}

fn buildSessionStart(gpa: std.mem.Allocator) !void {
    const request = try sessionStarted(gpa, .{
        .session_id = @splat(1),
        .pane_id = @enumFromInt(7),
        .location = test_location,
        .workspace_path = "/work/telar",
        .shell = "/bin/sh",
        .started_at_ms = 1_000,
    });
    defer model.deinitRequest(request, gpa);
}

fn buildCommand(gpa: std.mem.Allocator) !void {
    const request = try commandFinished(gpa, .{
        .context = .{
            .session_id = @splat(1),
            .pane_id = @enumFromInt(7),
            .location = test_location,
            .sequence = 4,
            .workspace_path = "/work/telar",
            .cols = 80,
            .rows = 24,
        },
        .command = .{
            .bytes = "zig build test",
            .cwd = "/work/telar",
            .started_at_ms = 1_000,
            .duration_ns = 20,
            .exit_code = 0,
            .status = .completed,
            .truncated = false,
            .output = "All tests passed",
            .output_observed = 16,
        },
    });
    defer model.deinitRequest(request, gpa);
}

test "owned request construction releases every partial allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildLaunchAttempt, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildSessionStart, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildCommand, .{});
}

test "a command request owns every byte borrowed from the terminal" {
    var command_bytes = "zig test".*;
    var cwd = "/work".*;
    var workspace = "/repo".*;
    var output = "passed".*;
    const request = try commandFinished(std.testing.allocator, .{
        .context = .{
            .session_id = @splat(1),
            .pane_id = @enumFromInt(7),
            .location = test_location,
            .sequence = 4,
            .workspace_path = &workspace,
            .cols = 80,
            .rows = 24,
        },
        .command = .{
            .bytes = &command_bytes,
            .cwd = &cwd,
            .started_at_ms = 1_000,
            .duration_ns = 20,
            .exit_code = 0,
            .status = .completed,
            .truncated = false,
            .output = &output,
            .output_observed = output.len,
        },
    });
    defer model.deinitRequest(request, std.testing.allocator);

    @memset(&command_bytes, 'x');
    @memset(&cwd, 'x');
    @memset(&workspace, 'x');
    @memset(&output, 'x');

    const value = request.command_finished;

    try std.testing.expectEqualStrings("zig test", value.command);
    try std.testing.expectEqualStrings("/work", value.cwd);
    try std.testing.expectEqualStrings("/repo", value.workspace_path);
    try std.testing.expectEqualStrings("passed", value.output);
}
