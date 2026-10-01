const std = @import("std");
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const ClientKey = @import("../history/ClientKey.zig");
const Executions = @import("../execution/Executions.zig");
const ExecutionPipes = @import("../execution/ExecutionPipes.zig");
const ExecutionCompletion = @import("../execution/ExecutionCompletion.zig");
const execution_io = @import("../execution/execution_io.zig");
const client_request = @import("client_request.zig");
const limit_reached = @import("limit_reached.zig");

/// Applies one operation without waiting for process or pipe I/O. Example: `try execution.request(model, session, operation);`.
pub fn request(model: *RuntimeModel, session: *Session, operation: core.ExecutionRequest) !void {
    const reply = operate(model, session, operation) catch |err| {
        if (err == error.ExecutionLimitReached) {
            limit_reached.report(model, .{ .limit = Executions.limit, .requested = Executions.capacity + 1 });
        }

        return client_request.fail(session, operation.request_id, if (err == error.ExecutionLimitReached) .resource_limit else .invalid_request, @errorName(err));
    };
    try session.delivery.responses.push(.{ .execution_reply = reply });
}

fn operate(model: *RuntimeModel, session: *Session, operation: core.ExecutionRequest) !core.ExecutionReply {
    const executions = &model.executions;
    if (operation.action == .list) {
        var selected: ?usize = null;
        for (executions.id, 0..) |id, index| {
            if (id > operation.execution_id and (selected == null or id < executions.id[selected.?])) {
                selected = index;
            }
        }

        const index = selected orelse return .{ .request_id = operation.request_id, .execution_id = 0, .state = .exited };
        return .{
            .request_id = operation.request_id,
            .execution_id = executions.id[index],
            .workspace_id = core.raw(executions.workspace[index]),
            .state = if (executions.state[index] == .starting and executions.pipes[index].?.started.load(.acquire)) .running else executions.state[index],
            .exit_code = executions.exit_code[index],
        };
    }

    const slot = executions.find(operation.execution_id) orelse blk: {
        if (operation.action != .start) {
            return error.ExecutionNotFound;
        }

        break :blk try start(model, session, operation);
    };
    if (operation.action == .start) {
        const hash = launchHash(operation);
        if (!std.mem.eql(u8, &executions.launch_hash[slot], &hash)) {
            return error.ExecutionIdentityConflict;
        }
    }

    const pipes = executions.pipes[slot].?;
    if (operation.action == .input and (executions.stdin_owner[slot] == null or !std.meta.eql(executions.stdin_owner[slot].?, session.key))) {
        return error.ExecutionInputOwned;
    }
    if (operation.action == .cancel) {
        pipes.cancel.store(true, .release);
    }

    if (operation.action == .eof) {
        pipes.eof.store(true, .release);
    }

    if (!pipes.guard.tryLock()) {
        return error.ExecutionBusy;
    }

    var reply: core.ExecutionReply = .{
        .request_id = operation.request_id,
        .execution_id = operation.execution_id,
        .workspace_id = core.raw(executions.workspace[slot]),
        .state = if (executions.state[slot] == .starting and pipes.started.load(.acquire)) .running else executions.state[slot],
        .exit_code = executions.exit_code[slot],
    };
    {
        defer pipes.guard.unlock();
        if (operation.action == .input) {
            if (operation.input_offset > pipes.input_written) {
                return error.ExecutionInputGap;
            }

            if (operation.input_offset == pipes.input_written) {
                if (pipes.eof.load(.acquire)) {
                    return error.ExecutionInputClosed;
                }

                if (operation.bytes.len > pipes.input.len - (pipes.input_written - pipes.input_read)) {
                    return error.ExecutionBusy;
                }

                for (operation.bytes) |byte| {
                    pipes.input[pipes.input_written % pipes.input.len] = byte;
                    pipes.input_written += 1;
                }
            } else if (operation.input_offset + operation.bytes.len > pipes.input_written) {
                return error.ExecutionInputOverlap;
            }
        }

        if (executions.failure[slot]) |failure| {
            const name = @errorName(failure);
            reply.failure_len = @intCast(@min(name.len, reply.failure.len));
            @memcpy(reply.failure[0..reply.failure_len], name[0..reply.failure_len]);
        }

        reply.input_available = pipes.input.len - (pipes.input_written - pipes.input_read);
        reply.input_offset = pipes.input_written;
        reply.stdin_open = !pipes.eof.load(.acquire);
        reply.stdout_total = pipes.stdout_total;
        reply.stderr_total = pipes.stderr_total;
        reply.stdout_offset = @max(operation.stdout_offset, pipes.stdout_total -| pipes.stdout.len);
        reply.stderr_offset = @max(operation.stderr_offset, pipes.stderr_total -| pipes.stderr.len);
        reply.stdout_len = read(&reply.stdout, &pipes.stdout, pipes.stdout_total, reply.stdout_offset);
        reply.stderr_len = read(&reply.stderr, &pipes.stderr, pipes.stderr_total, reply.stderr_offset);
    }

    if (reply.stdout_offset != operation.stdout_offset or reply.stderr_offset != operation.stderr_offset) {
        limit_reached.report(model, .{ .limit = ExecutionPipes.retention_limit, .requested = @max(reply.stdout_total, reply.stderr_total) });
    }

    if (operation.action == .forget) {
        if (executions.state[slot] != .exited and executions.state[slot] != .failed) {
            return error.ExecutionStillRunning;
        }

        executions.remove(model.gpa, slot);
    }

    return reply;
}

fn start(model: *RuntimeModel, session: *Session, operation: core.ExecutionRequest) !usize {
    const slot = try model.executions.add(operation.execution_id);
    errdefer model.executions.remove(model.gpa, slot);
    const workspace = if (operation.workspace_id != 0) try core.workspace(operation.workspace_id) else try administration(model);
    errdefer releaseAdministration(model);
    const workspace_slot = model.workspaces.slotOf(.{ .workspace = workspace }) orelse return error.WorkspaceNotFound;
    const cwd = if (operation.cwd.len != 0) operation.cwd else model.workspaces.path[workspace_slot];
    const pipes = try model.gpa.create(ExecutionPipes);
    errdefer model.gpa.destroy(pipes);
    const owned_cwd = try model.gpa.dupe(u8, cwd);
    errdefer model.gpa.free(owned_cwd);
    const arguments = try model.gpa.alloc([]const u8, operation.argument_count);
    errdefer model.gpa.free(arguments);
    var copied: usize = 0;
    errdefer for (arguments[0..copied]) |argument| {
        model.gpa.free(argument);
    };
    for (arguments, operation.arguments[0..operation.argument_count]) |*owned, argument| {
        owned.* = try model.gpa.dupe(u8, argument);
        copied += 1;
    }

    pipes.* = .{
        .cwd = owned_cwd,
        .arguments = arguments,
        .environ = model.inherited_environment,
        .id = operation.execution_id,
    };
    pipes.eof.store(!operation.stdin_open, .release);
    try model.select.concurrent(.execution_finished, execution_io.start, .{ model.io, pipes });
    model.executions.pipes[slot] = pipes;
    model.executions.workspace[slot] = workspace;
    model.executions.stdin_owner[slot] = if (operation.stdin_open) session.key else null;
    model.executions.launch_hash[slot] = launchHash(operation);
    return slot;
}

fn administration(model: *RuntimeModel) !core.WorkspaceId {
    if (model.administration_workspace != .invalid and model.workspaces.slotOf(.{ .workspace = model.administration_workspace }) != null) {
        return model.administration_workspace;
    }

    const home = model.home orelse return error.DestinationHomeUnavailable;
    const location = try model.workspaces.insert(model.gpa, home, "Administration");
    model.administration_workspace = location.workspace.workspace;
    return model.administration_workspace;
}

fn launchHash(operation: core.ExecutionRequest) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(std.mem.asBytes(&operation.workspace_id));
    const cwd_length: u64 = operation.cwd.len;
    hash.update(std.mem.asBytes(&cwd_length));
    hash.update(operation.cwd);
    hash.update(&.{ @intFromBool(operation.stdin_open), operation.argument_count });
    for (operation.arguments[0..operation.argument_count]) |argument| {
        const length: u64 = argument.len;
        hash.update(std.mem.asBytes(&length));
        hash.update(argument);
    }

    return hash.finalResult();
}

fn read(destination: []u8, buffer: []const u8, total: u64, offset: u64) u16 {
    const count: usize = @intCast(@min(destination.len, total -| offset));
    for (destination[0..count], 0..) |*byte, index| {
        byte.* = buffer[(offset + index) % buffer.len];
    }

    return @intCast(count);
}

/// Commits a joined worker result independently of its requesting client. Example: `execution.finish(model, completion);`.
pub fn finish(model: *RuntimeModel, completion: ExecutionCompletion) void {
    const slot = model.executions.find(completion.id) orelse return;
    model.executions.state[slot] = .exited;
    model.executions.exit_code[slot] = completion.result catch |err| blk: {
        model.executions.failure[slot] = err;
        model.executions.state[slot] = .failed;
        break :blk 125;
    };
    model.executions.stdin_owner[slot] = null;
    model.executions.pipes[slot].?.eof.store(true, .release);
    releaseAdministration(model);
}

fn releaseAdministration(model: *RuntimeModel) void {
    for (model.executions.id, 0..) |id, other| {
        if (id != 0 and model.executions.workspace[other] == model.administration_workspace and (model.executions.state[other] == .starting or model.executions.state[other] == .running)) {
            return;
        }
    }

    // A person may have added real panes to this workspace meanwhile.
    for (model.panes.items) |entry| {
        const pane = entry orelse continue;
        if (pane.location.workspace.workspace == model.administration_workspace) {
            return;
        }
    }

    if (model.administration_workspace != .invalid) {
        _ = model.workspaces.remove(model.gpa, model.administration_workspace);
        model.administration_workspace = .invalid;
    }
}

/// Client death delivers EOF, never cancellation. Example: `execution.disconnect(model, key);`.
pub fn disconnect(model: *RuntimeModel, key: ClientKey) void {
    for (model.executions.stdin_owner, 0..) |owner, slot| {
        if (owner != null and std.meta.eql(owner.?, key)) {
            model.executions.pipes[slot].?.eof.store(true, .release);
            model.executions.stdin_owner[slot] = null;
        }
    }
}
