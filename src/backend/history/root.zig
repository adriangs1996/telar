//! Command history capture and persistence.

const std = @import("std");
const diagnostics = @import("telar-core").diagnostics;
const model_mod = @import("model.zig");
const osc_mod = @import("osc.zig");
const store_mod = @import("store.zig");
const terminal_mod = @import("terminal.zig");
const observer_mod = @import("observer.zig");
const detection_mod = @import("agent_detection.zig");
const escape_mod = @import("escape.zig");

pub const model = model_mod;
pub const osc = osc_mod;
pub const terminal = terminal_mod;
pub const observer = observer_mod;
pub const detection = detection_mod;
pub const escape = escape_mod;
pub const Tracker = terminal_mod.Tracker;
pub const Command = terminal_mod.Command;
pub const Clock = terminal_mod.Clock;
pub const Status = terminal_mod.Status;
pub const Query = model_mod.Query;
pub const Response = model_mod.Response;
pub const SessionId = model_mod.SessionId;
pub const LaunchPhase = model_mod.LaunchPhase;

const request_capacity = 64;
const response_capacity = 4;

pub const Service = struct {
    gpa: std.mem.Allocator,
    database_path: [:0]const u8,
    requests: std.Io.Queue(model_mod.Request),
    responses: std.Io.Queue(model_mod.Response),
    request_storage: []model_mod.Request,
    response_storage: []model_mod.Response,
    store: ?store_mod.Store,
    open_error: ?anyerror = null,
    stats: Stats = .{},

    pub const Stats = struct {
        queued: std.atomic.Value(u64) = .init(0),
        queue_high_water: std.atomic.Value(u64) = .init(0),
        dropped: std.atomic.Value(u64) = .init(0),
        sqlite_writes: std.atomic.Value(u64) = .init(0),
        sqlite_write_failures: std.atomic.Value(u64) = .init(0),
        sqlite_write_ns: std.atomic.Value(u64) = .init(0),
        sqlite_write_max_ns: std.atomic.Value(u64) = .init(0),
        sqlite_queries: std.atomic.Value(u64) = .init(0),
        sqlite_query_failures: std.atomic.Value(u64) = .init(0),
        sqlite_query_ns: std.atomic.Value(u64) = .init(0),
        sqlite_query_max_ns: std.atomic.Value(u64) = .init(0),
        sqlite_open_failures: std.atomic.Value(u64) = .init(0),
    };

    pub const StatsSnapshot = struct {
        queued: u64,
        queue_high_water: u64,
        dropped: u64,
        sqlite_writes: u64,
        sqlite_write_failures: u64,
        sqlite_write_ns: u64,
        sqlite_write_max_ns: u64,
        sqlite_queries: u64,
        sqlite_query_failures: u64,
        sqlite_query_ns: u64,
        sqlite_query_max_ns: u64,
        sqlite_open_failures: u64,
        available: bool,
    };

    pub fn init(gpa: std.mem.Allocator, database_path: [:0]const u8) !Service {
        const request_storage = try gpa.alloc(model_mod.Request, request_capacity);
        errdefer gpa.free(request_storage);
        const response_storage = try gpa.alloc(model_mod.Response, response_capacity);
        errdefer gpa.free(response_storage);
        var open_error: ?anyerror = null;
        const store = store_mod.Store.open(database_path) catch |err| unavailable: {
            open_error = err;
            break :unavailable null;
        };
        var service: Service = .{
            .gpa = gpa,
            .database_path = database_path,
            .requests = .init(request_storage),
            .responses = .init(response_storage),
            .request_storage = request_storage,
            .response_storage = response_storage,
            // History remains best effort, but degradation is explicit in
            // status and telemetry instead of being erased at startup.
            .store = store,
            .open_error = open_error,
        };
        if (open_error != null)
            _ = service.stats.sqlite_open_failures.fetchAdd(1, .monotonic);
        return service;
    }

    pub fn closeQueues(service: *Service, io: std.Io) void {
        service.requests.close(io);
        service.responses.close(io);
    }

    pub fn deinit(service: *Service, io: std.Io) void {
        service.responses.close(io);
        var request_buffer: [8]model_mod.Request = undefined;
        while (true) {
            const count = service.requests.get(io, &request_buffer, 0) catch break;
            if (count == 0) break;
            for (request_buffer[0..count]) |request|
                model_mod.deinitRequest(request, service.gpa);
        }
        var response_buffer: [4]model_mod.Response = undefined;
        while (true) {
            const count = service.responses.get(io, &response_buffer, 0) catch break;
            if (count == 0) break;
            for (response_buffer[0..count]) |response|
                model_mod.deinitResponse(response, service.gpa);
        }
        if (service.store) |*store| store.close();
        service.gpa.free(service.response_storage);
        service.gpa.free(service.request_storage);
    }

    pub fn newSessionId(_: *Service, io: std.Io) SessionId {
        var session_id: SessionId = undefined;
        io.random(&session_id);
        return session_id;
    }

    pub fn recordLaunchAttempt(
        service: *Service,
        io: std.Io,
        pane_id: model_mod.schema.PaneId,
        pane_generation: u64,
        location: model_mod.schema.TabLocation,
        workspace_path: []const u8,
        shell: []const u8,
        started_at_ms: i64,
        phase: LaunchPhase,
        cause: []const u8,
    ) bool {
        const value = service.gpa.create(model_mod.LaunchAttempt) catch return false;
        value.* = .{
            .pane_id = pane_id,
            .pane_generation = pane_generation,
            .location = location,
            .started_at_ms = started_at_ms,
            .failed_at_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
            .phase = phase,
            .workspace_path = service.gpa.dupe(u8, workspace_path) catch {
                service.gpa.destroy(value);
                return false;
            },
            .shell = service.gpa.dupe(u8, shell) catch {
                service.gpa.free(value.workspace_path);
                service.gpa.destroy(value);
                return false;
            },
            .cause = service.gpa.dupe(u8, cause) catch {
                service.gpa.free(value.shell);
                service.gpa.free(value.workspace_path);
                service.gpa.destroy(value);
                return false;
            },
        };
        return service.submit(io, .{ .launch_attempt = value });
    }

    pub fn startSession(
        service: *Service,
        io: std.Io,
        session_id: SessionId,
        pane_id: model_mod.schema.PaneId,
        location: model_mod.schema.TabLocation,
        workspace_path: []const u8,
        shell: []const u8,
        started_at_ms: i64,
    ) bool {
        const value = service.gpa.create(model_mod.SessionStarted) catch return false;
        value.* = .{
            .id = session_id,
            .pane_id = pane_id,
            .location = location,
            .started_at_ms = started_at_ms,
            .workspace_path = service.gpa.dupe(u8, workspace_path) catch {
                service.gpa.destroy(value);
                return false;
            },
            .shell = service.gpa.dupe(u8, shell) catch {
                service.gpa.free(value.workspace_path);
                service.gpa.destroy(value);
                return false;
            },
        };
        return service.submit(io, .{ .session_started = value });
    }

    pub fn finishSession(
        service: *Service,
        io: std.Io,
        session_id: SessionId,
        finished_at_ms: i64,
    ) bool {
        return service.submit(io, .{ .session_finished = .{
            .id = session_id,
            .finished_at_ms = finished_at_ms,
        } });
    }

    pub fn setSessionTitle(
        service: *Service,
        io: std.Io,
        session_id: SessionId,
        title: []const u8,
        source: model_mod.schema.AgentTitleSource,
        state: model_mod.schema.AgentTitleState,
    ) bool {
        const value = model_mod.SessionTitle.init(
            session_id,
            title,
            source,
            state,
        ) catch return false;
        return service.submit(io, .{ .session_title = value });
    }

    pub const CommandContext = struct {
        session_id: SessionId,
        pane_id: model_mod.schema.PaneId,
        location: model_mod.schema.TabLocation,
        sequence: u64,
        workspace_path: []const u8,
        cols: u16,
        rows: u16,
    };

    pub fn recordCommand(
        service: *Service,
        io: std.Io,
        context: CommandContext,
        command: terminal_mod.Command,
    ) bool {
        const allocation_len = @sizeOf(model_mod.CommandFinished) + command.bytes.len +
            command.cwd.len + context.workspace_path.len;
        const allocation = service.gpa.alignedAlloc(
            u8,
            .of(model_mod.CommandFinished),
            allocation_len,
        ) catch return false;
        const value: *model_mod.CommandFinished = @ptrCast(allocation);
        var cursor: usize = @sizeOf(model_mod.CommandFinished);
        const command_copy = allocation[cursor..][0..command.bytes.len];
        cursor += command_copy.len;
        const cwd_copy = allocation[cursor..][0..command.cwd.len];
        cursor += cwd_copy.len;
        const workspace_copy = allocation[cursor..][0..context.workspace_path.len];
        @memcpy(command_copy, command.bytes);
        @memcpy(cwd_copy, command.cwd);
        @memcpy(workspace_copy, context.workspace_path);
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
            .cols = context.cols,
            .rows = context.rows,
            .command = command_copy,
            .cwd = cwd_copy,
            .workspace_path = workspace_copy,
            .command_truncated = command.truncated,
        };
        return service.submit(io, .{ .command_finished = value });
    }

    pub fn query(service: *Service, io: std.Io, request: model_mod.Query) bool {
        return service.submit(io, .{ .query = request });
    }

    pub fn statsSnapshot(service: *const Service) StatsSnapshot {
        return .{
            .queued = service.stats.queued.load(.monotonic),
            .queue_high_water = service.stats.queue_high_water.load(.monotonic),
            .dropped = service.stats.dropped.load(.monotonic),
            .sqlite_writes = service.stats.sqlite_writes.load(.monotonic),
            .sqlite_write_failures = service.stats.sqlite_write_failures.load(.monotonic),
            .sqlite_write_ns = service.stats.sqlite_write_ns.load(.monotonic),
            .sqlite_write_max_ns = service.stats.sqlite_write_max_ns.load(.monotonic),
            .sqlite_queries = service.stats.sqlite_queries.load(.monotonic),
            .sqlite_query_failures = service.stats.sqlite_query_failures.load(.monotonic),
            .sqlite_query_ns = service.stats.sqlite_query_ns.load(.monotonic),
            .sqlite_query_max_ns = service.stats.sqlite_query_max_ns.load(.monotonic),
            .sqlite_open_failures = service.stats.sqlite_open_failures.load(.monotonic),
            .available = service.store != null,
        };
    }

    pub fn sqliteBytes(service: *const Service, io: std.Io) u64 {
        if (std.mem.eql(u8, service.database_path, ":memory:")) return 0;
        const stat = std.Io.Dir.cwd().statFile(
            io,
            service.database_path,
            .{ .follow_symlinks = false },
        ) catch return 0;
        if (stat.size < 0) return 0;
        return @intCast(stat.size);
    }

    pub fn openError(service: *const Service) ?anyerror {
        return service.open_error;
    }

    fn submit(service: *Service, io: std.Io, request: model_mod.Request) bool {
        const queued = service.stats.queued.fetchAdd(1, .monotonic) + 1;
        const count = service.requests.put(io, &.{request}, 0) catch 0;
        if (count == 1) {
            _ = service.stats.queue_high_water.fetchMax(queued, .monotonic);
            return true;
        }
        _ = service.stats.queued.fetchSub(1, .monotonic);
        _ = service.stats.dropped.fetchAdd(1, .monotonic);
        model_mod.deinitRequest(request, service.gpa);
        return false;
    }
};

pub fn runWorker(io: std.Io, service: *Service) anyerror!void {
    while (true) {
        const request = service.requests.getOne(io) catch |err| switch (err) {
            error.Closed => return,
            else => |other| return other,
        };
        const path = diagnostics.enter(.observation);
        defer path.restore();
        _ = service.stats.queued.fetchSub(1, .monotonic);
        switch (request) {
            .launch_attempt => |value| {
                defer value.deinit(service.gpa);
                const started = std.Io.Timestamp.now(io, .awake);
                const result = if (service.store) |*store|
                    store.insertLaunchAttempt(value)
                else
                    error.HistoryUnavailable;
                observeWrite(service, elapsedSince(io, started), result);
            },
            .session_started => |value| {
                defer value.deinit(service.gpa);
                const started = std.Io.Timestamp.now(io, .awake);
                const result = if (service.store) |*store|
                    store.startSession(value)
                else
                    error.HistoryUnavailable;
                observeWrite(service, elapsedSince(io, started), result);
            },
            .session_finished => |value| {
                const started = std.Io.Timestamp.now(io, .awake);
                const result = if (service.store) |*store|
                    store.finishSession(value)
                else
                    error.HistoryUnavailable;
                observeWrite(service, elapsedSince(io, started), result);
            },
            .session_title => |value| {
                const started = std.Io.Timestamp.now(io, .awake);
                const result = if (service.store) |*store|
                    store.setSessionTitle(&value)
                else
                    error.HistoryUnavailable;
                observeWrite(service, elapsedSince(io, started), result);
            },
            .command_finished => |value| {
                defer value.deinit(service.gpa);
                const started = std.Io.Timestamp.now(io, .awake);
                const result = if (service.store) |*store|
                    store.insertCommand(value)
                else
                    error.HistoryUnavailable;
                observeWrite(service, elapsedSince(io, started), result);
            },
            .query => |query_value| {
                const started = std.Io.Timestamp.now(io, .awake);
                const response: model_mod.Response = if (service.store) |*store|
                    if (store.query(service.gpa, &query_value)) |result|
                        .{ .query_result = result }
                    else |_|
                        .{ .failed = .{
                            .request_id = query_value.request_id,
                            .origin = query_value.origin,
                            .message = "history query failed",
                        } }
                else
                    .{ .failed = .{
                        .request_id = query_value.request_id,
                        .origin = query_value.origin,
                        .message = "history database is unavailable",
                    } };
                const elapsed = elapsedNs(started, std.Io.Timestamp.now(io, .awake));
                _ = service.stats.sqlite_queries.fetchAdd(1, .monotonic);
                _ = service.stats.sqlite_query_ns.fetchAdd(elapsed, .monotonic);
                _ = service.stats.sqlite_query_max_ns.fetchMax(elapsed, .monotonic);
                if (response == .failed)
                    _ = service.stats.sqlite_query_failures.fetchAdd(1, .monotonic);
                service.responses.putOne(io, response) catch |err| {
                    model_mod.deinitResponse(response, service.gpa);
                    if (err == error.Closed) return;
                    return err;
                };
            },
        }
    }
}

fn observeWrite(service: *Service, elapsed: u64, result: anyerror!void) void {
    _ = service.stats.sqlite_writes.fetchAdd(1, .monotonic);
    _ = service.stats.sqlite_write_ns.fetchAdd(elapsed, .monotonic);
    _ = service.stats.sqlite_write_max_ns.fetchMax(elapsed, .monotonic);
    result catch {
        _ = service.stats.sqlite_write_failures.fetchAdd(1, .monotonic);
    };
}

fn elapsedSince(io: std.Io, started: std.Io.Timestamp) u64 {
    return elapsedNs(started, std.Io.Timestamp.now(io, .awake));
}

fn elapsedNs(started: std.Io.Timestamp, finished: std.Io.Timestamp) u64 {
    return @intCast(@max(@as(i96, 0), finished.nanoseconds - started.nanoseconds));
}

pub fn receiveResponse(io: std.Io, service: *Service) anyerror!model_mod.Response {
    return service.responses.getOne(io);
}

test {
    std.testing.refAllDecls(@This());
}

test "database open degradation is explicit" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &path_buffer,
        "{s}/missing/history.db",
        .{directory_buffer[0..directory_len]},
    );

    var service = try Service.init(std.testing.allocator, path);
    defer service.deinit(io);
    const stats = service.statsSnapshot();
    try std.testing.expect(!stats.available);
    try std.testing.expectEqual(@as(u64, 1), stats.sqlite_open_failures);
    try std.testing.expect(service.openError() != null);
}

test "sqliteBytes is zero for an in-memory database" {
    const io = std.testing.io;
    var service = try Service.init(std.testing.allocator, ":memory:");
    defer service.deinit(io);
    try std.testing.expectEqual(@as(u64, 0), service.sqliteBytes(io));
}

test "sqliteBytes reports the on-disk history file" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &path_buffer,
        "{s}/history.db",
        .{directory_buffer[0..directory_len]},
    );
    var service = try Service.init(std.testing.allocator, path);
    defer service.deinit(io);
    try std.testing.expect(service.statsSnapshot().available);
    try std.testing.expect(service.sqliteBytes(io) > 0);
}

test "launch attempt recording releases every partial allocation" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fail_index: usize = 0;
    var completed = false;
    while (!completed) : (fail_index += 1) {
        try std.testing.expect(fail_index < 8);
        var service = try Service.init(gpa, ":memory:");
        var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        service.gpa = failing.allocator();
        completed = service.recordLaunchAttempt(
            io,
            @enumFromInt(7),
            3,
            .{
                .workspace = .{ .workspace = @enumFromInt(2) },
                .tab_id = @enumFromInt(5),
            },
            "/work/telar",
            "/bin/sh",
            1_000,
            .output_actor,
            "InjectedLaunchFailure",
        );
        service.deinit(io);
    }
}
