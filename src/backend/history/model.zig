//! Owned values exchanged with the history worker.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;

pub const max_query_bytes = schema.max_history_query_bytes;
pub const max_results = schema.max_history_results;
pub const max_result_payload_bytes = core.transport.max_frame_size;
pub const encoded_result_header_bytes = 11;
pub const encoded_entry_overhead_bytes = 49;

pub const SessionId = [16]u8;

pub const LaunchPhase = enum(u8) {
    pane_registration = 0,
    wait_actor = 1,
    output_actor = 2,
};

pub const ClientKey = struct {
    id: u64,
    generation: u64,
};

pub const CommandStatus = enum(u8) {
    completed = 0,
    interrupted = 1,
    running = 2,
};

pub const SessionStarted = struct {
    id: SessionId,
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    started_at_ms: i64,
    workspace_path: []u8,
    shell: []u8,

    pub fn deinit(value: *SessionStarted, gpa: std.mem.Allocator) void {
        gpa.free(value.workspace_path);
        gpa.free(value.shell);
        gpa.destroy(value);
    }
};

pub const SessionFinished = struct {
    id: SessionId,
    finished_at_ms: i64,
};

pub const SessionTitle = struct {
    pub const Definition = struct {
        id: SessionId,
        title: []const u8,
        source: schema.AgentTitleSource,
        state: schema.AgentTitleState,
    };

    id: SessionId,
    title: [schema.max_agent_session_title_bytes]u8 = undefined,
    title_len: u8 = 0,
    source: schema.AgentTitleSource,
    state: schema.AgentTitleState,

    /// Validates and owns the fixed-size representation persisted by history.
    ///
    /// ```zig
    /// const title = try SessionTitle.init(.{ .id = id, .title = "Fix tests", .source = .generated, .state = .ready });
    /// ```
    pub fn init(definition: Definition) !SessionTitle {
        const id = definition.id;
        const title_value = definition.title;
        const source = definition.source;
        const state = definition.state;

        if (title_value.len > schema.max_agent_session_title_bytes)
            return error.AgentTitleTooLong;
        if (!std.unicode.utf8ValidateSlice(title_value)) return error.InvalidAgentTitle;
        for (title_value) |byte| if (byte < 0x20 or byte == 0x7f)
            return error.InvalidAgentTitle;
        switch (source) {
            .telar => if (state == .ready) return error.InvalidAgentTitle,
            .generated, .manual => if (state != .ready or title_value.len == 0)
                return error.InvalidAgentTitle,
            // A child's own window title is never persisted as a session title.
            .terminal => return error.InvalidAgentTitle,
        }
        var value: SessionTitle = .{
            .id = id,
            .title_len = @intCast(title_value.len),
            .source = source,
            .state = state,
        };
        @memcpy(value.title[0..title_value.len], title_value);
        return value;
    }

    pub fn titleSlice(value: *const SessionTitle) []const u8 {
        return value.title[0..value.title_len];
    }
};

test "session titles validate text and source authority before persistence" {
    const session_id = [_]u8{1} ** 16;
    _ = try SessionTitle.init(.{ .id = session_id, .title = "Improve sidebar", .source = .generated, .state = .ready });
    _ = try SessionTitle.init(.{ .id = session_id, .title = "", .source = .telar, .state = .failed });
    try std.testing.expectError(
        error.InvalidAgentTitle,
        SessionTitle.init(.{ .id = session_id, .title = "bad\ntitle", .source = .generated, .state = .ready }),
    );
    try std.testing.expectError(
        error.InvalidAgentTitle,
        SessionTitle.init(.{ .id = session_id, .title = "", .source = .generated, .state = .ready }),
    );
    try std.testing.expectError(
        error.InvalidAgentTitle,
        SessionTitle.init(.{ .id = session_id, .title = "manual", .source = .manual, .state = .pending }),
    );
}

pub const LaunchAttempt = struct {
    pane_id: schema.PaneId,
    pane_generation: u64,
    location: schema.TabLocation,
    started_at_ms: i64,
    failed_at_ms: i64,
    phase: LaunchPhase,
    workspace_path: []u8,
    shell: []u8,
    cause: []u8,

    pub fn deinit(value: *LaunchAttempt, gpa: std.mem.Allocator) void {
        gpa.free(value.workspace_path);
        gpa.free(value.shell);
        gpa.free(value.cause);
        gpa.destroy(value);
    }
};

pub const CommandFinished = struct {
    session_id: SessionId,
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    sequence: u64,
    started_at_ms: i64,
    duration_ns: i64,
    exit_code: ?i32,
    status: CommandStatus,
    author: schema.HistoryAuthor,
    origin: schema.HistoryOrigin = .pane,
    cols: u16,
    rows: u16,
    command: []u8,
    cwd: []u8,
    workspace_path: []u8,
    provider: []u8 = &.{},
    tool_call_id: []u8 = &.{},
    command_truncated: bool,
    output: []u8,
    output_truncated: bool,
    output_observed: u64,

    pub fn deinit(value: *CommandFinished, gpa: std.mem.Allocator) void {
        const allocation_len = @sizeOf(CommandFinished) + value.command.len +
            value.cwd.len + value.workspace_path.len + value.provider.len +
            value.tool_call_id.len + value.output.len;
        const allocation: [*]align(@alignOf(CommandFinished)) u8 = @ptrCast(value);
        gpa.free(allocation[0..allocation_len]);
    }
};

pub const Scope = schema.HistoryScope;

pub const QueryOrigin = struct {
    client: ClientKey,
    close_after_reply: bool,
};

pub const Query = struct {
    pub const Input = struct {
        request_id: schema.RequestId,
        origin: QueryOrigin,
        text: []const u8 = "",
        scope: Scope = .global,
        scope_value: []const u8 = "",
        pane_id: schema.PaneId = .invalid,
        failed_only: bool = false,
        author: schema.HistoryAuthorFilter = .all,
        match: schema.HistoryMatch = .fts,
        distinct: bool = false,
        limit: u16 = 20,
    };

    request_id: schema.RequestId,
    origin: QueryOrigin,
    text: [max_query_bytes]u8 = undefined,
    text_len: u16 = 0,
    scope: Scope = .global,
    scope_text: [schema.max_cwd_bytes]u8 = undefined,
    scope_text_len: u16 = 0,
    pane_id: schema.PaneId = .invalid,
    failed_only: bool = false,
    author: schema.HistoryAuthorFilter = .all,
    match: schema.HistoryMatch = .fts,
    distinct: bool = false,
    limit: u16 = 20,

    /// Copies a validated query into fixed storage so it can cross the
    /// asynchronous history queue without borrowing request-buffer bytes.
    ///
    /// ```zig
    /// const query = try Query.init(.{
    ///     .request_id = request_id,
    ///     .origin = origin,
    ///     .text = "git",
    /// });
    /// ```
    pub fn init(input: Input) !Query {
        if (input.text.len > max_query_bytes) {
            return error.QueryTooLong;
        }

        if (input.scope_value.len > schema.max_cwd_bytes) {
            return error.ScopeTooLong;
        }

        if (input.limit == 0 or input.limit > max_results) {
            return error.InvalidLimit;
        }

        if (input.scope == .pane and input.pane_id == .invalid) {
            return error.InvalidPaneId;
        }

        if (input.scope != .pane and input.pane_id != .invalid) {
            return error.UnexpectedPaneId;
        }

        var query: Query = .{
            .request_id = input.request_id,
            .origin = input.origin,
            .scope = input.scope,
            .pane_id = input.pane_id,
            .failed_only = input.failed_only,
            .author = input.author,
            .match = input.match,
            .distinct = input.distinct,
            .limit = input.limit,
        };
        @memcpy(query.text[0..input.text.len], input.text);
        query.text_len = @intCast(input.text.len);
        @memcpy(query.scope_text[0..input.scope_value.len], input.scope_value);
        query.scope_text_len = @intCast(input.scope_value.len);
        return query;
    }

    /// Returns the query text owned by this value.
    ///
    /// ```zig
    /// const text = query.textSlice();
    /// ```
    pub fn textSlice(query: *const Query) []const u8 {
        return query.text[0..query.text_len];
    }

    /// Returns the cwd or workspace scope text owned by this value.
    ///
    /// ```zig
    /// const scope = query.scopeSlice();
    /// ```
    pub fn scopeSlice(query: *const Query) []const u8 {
        return query.scope_text[0..query.scope_text_len];
    }
};

test "history queries own request text and scope bytes" {
    var text = [_]u8{ 'g', 'i', 't' };
    var scope = [_]u8{ '/', 'w', 'o', 'r', 'k' };
    const query = try Query.init(.{
        .request_id = @enumFromInt(7),
        .origin = .{
            .client = .{ .id = 3, .generation = 4 },
            .close_after_reply = true,
        },
        .text = &text,
        .scope = .workspace,
        .scope_value = &scope,
        .failed_only = true,
        .limit = 9,
    });

    @memset(&text, 'x');
    @memset(&scope, 'y');

    try std.testing.expectEqualStrings("git", query.textSlice());
    try std.testing.expectEqualStrings("/work", query.scopeSlice());
    try std.testing.expectEqual(@as(schema.RequestId, @enumFromInt(7)), query.request_id);
    try std.testing.expectEqual(@as(u64, 3), query.origin.client.id);
    try std.testing.expectEqual(@as(u64, 4), query.origin.client.generation);
    try std.testing.expect(query.origin.close_after_reply);
    try std.testing.expectEqual(Scope.workspace, query.scope);
    try std.testing.expect(query.failed_only);
    try std.testing.expectEqual(@as(u16, 9), query.limit);
}

test "history query validation rejects values that cannot enter the worker" {
    const origin: QueryOrigin = .{
        .client = .{ .id = 1, .generation = 2 },
        .close_after_reply = false,
    };
    const long_text = [_]u8{'q'} ** (max_query_bytes + 1);
    const long_scope = [_]u8{'s'} ** (schema.max_cwd_bytes + 1);

    try std.testing.expectError(error.QueryTooLong, Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .text = &long_text,
    }));
    try std.testing.expectError(error.ScopeTooLong, Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .scope_value = &long_scope,
    }));
    try std.testing.expectError(error.InvalidLimit, Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .limit = 0,
    }));
    try std.testing.expectError(error.InvalidLimit, Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .limit = max_results + 1,
    }));
    try std.testing.expectError(error.InvalidPaneId, Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .scope = .pane,
    }));
    try std.testing.expectError(error.UnexpectedPaneId, Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .pane_id = @enumFromInt(2),
    }));
}

pub const Request = union(enum) {
    launch_attempt: *LaunchAttempt,
    session_started: *SessionStarted,
    session_finished: SessionFinished,
    session_title: SessionTitle,
    command_finished: *CommandFinished,
    query: Query,
    import: *ImportBatch,
    delete: Delete,
    prune: Prune,
    read_output: Delete,
    stats: StatsQuery,
};

/// Bounded owned stats filters.
pub const StatsQuery = struct {
    pub const Input = struct {
        request_id: schema.RequestId,
        origin: QueryOrigin,
        scope: Scope = .global,
        scope_value: []const u8 = "",
        pane_id: schema.PaneId = .invalid,
        since_ms: i64 = 0,
    };

    request_id: schema.RequestId,
    origin: QueryOrigin,
    scope: Scope = .global,
    scope_text: [schema.max_cwd_bytes]u8 = undefined,
    scope_text_len: u16 = 0,
    pane_id: schema.PaneId = .invalid,
    since_ms: i64 = 0,

    pub fn init(input: Input) !StatsQuery {
        if (input.scope_value.len > schema.max_cwd_bytes) {
            return error.ScopeTooLong;
        }
        if (input.scope == .pane and input.pane_id == .invalid) {
            return error.InvalidPaneId;
        }
        if (input.scope != .pane and input.pane_id != .invalid) {
            return error.UnexpectedPaneId;
        }

        var query: StatsQuery = .{
            .request_id = input.request_id,
            .origin = input.origin,
            .scope = input.scope,
            .pane_id = input.pane_id,
            .since_ms = input.since_ms,
        };
        @memcpy(query.scope_text[0..input.scope_value.len], input.scope_value);
        query.scope_text_len = @intCast(input.scope_value.len);
        return query;
    }

    pub fn scopeSlice(query: *const StatsQuery) []const u8 {
        return query.scope_text[0..query.scope_text_len];
    }
};

pub const StatsTop = struct {
    count: u64,
    command: []u8,
};

/// Owned aggregate result for one stats query.
pub const StatsResult = struct {
    request_id: schema.RequestId,
    origin: QueryOrigin,
    total: u64,
    unique: u64,
    top: []StatsTop,
    gpa: std.mem.Allocator,

    pub fn deinit(result: *StatsResult) void {
        for (result.top) |entry| result.gpa.free(entry.command);
        result.gpa.free(result.top);
        result.gpa.destroy(result);
    }
};

pub const Delete = struct {
    request_id: schema.RequestId,
    origin: QueryOrigin,
    id: u64,
};

/// Bounded owned prune filters, mirroring `Query`'s storage discipline.
pub const Prune = struct {
    pub const Input = struct {
        request_id: schema.RequestId,
        origin: QueryOrigin,
        scope: Scope = .global,
        scope_value: []const u8 = "",
        pane_id: schema.PaneId = .invalid,
        before_ms: i64 = 0,
        failed_only: bool = false,
        match: []const u8 = "",
    };

    request_id: schema.RequestId,
    origin: QueryOrigin,
    scope: Scope = .global,
    scope_text: [schema.max_cwd_bytes]u8 = undefined,
    scope_text_len: u16 = 0,
    pane_id: schema.PaneId = .invalid,
    before_ms: i64 = 0,
    failed_only: bool = false,
    match: [max_query_bytes]u8 = undefined,
    match_len: u16 = 0,

    pub fn init(input: Input) !Prune {
        if (input.match.len > max_query_bytes) {
            return error.QueryTooLong;
        }
        if (input.scope_value.len > schema.max_cwd_bytes) {
            return error.ScopeTooLong;
        }
        if (input.scope == .pane and input.pane_id == .invalid) {
            return error.InvalidPaneId;
        }
        if (input.scope != .pane and input.pane_id != .invalid) {
            return error.UnexpectedPaneId;
        }

        var prune: Prune = .{
            .request_id = input.request_id,
            .origin = input.origin,
            .scope = input.scope,
            .pane_id = input.pane_id,
            .before_ms = input.before_ms,
            .failed_only = input.failed_only,
        };
        @memcpy(prune.scope_text[0..input.scope_value.len], input.scope_value);
        prune.scope_text_len = @intCast(input.scope_value.len);
        @memcpy(prune.match[0..input.match.len], input.match);
        prune.match_len = @intCast(input.match.len);
        return prune;
    }

    pub fn scopeSlice(prune: *const Prune) []const u8 {
        return prune.scope_text[0..prune.scope_text_len];
    }

    pub fn matchSlice(prune: *const Prune) []const u8 {
        return prune.match[0..prune.match_len];
    }
};

pub const Pruned = struct {
    request_id: schema.RequestId,
    origin: QueryOrigin,
    removed: u64,
};

/// One owned batch of imported foreign history. The session identity is
/// derived deterministically from the source label, so re-imports reuse the
/// same session and `INSERT OR IGNORE` keeps them idempotent.
pub const ImportBatch = struct {
    session_id: SessionId,
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    base_sequence: u64,
    started_at_ms: i64,
    source: []u8,
    times: []i64,
    commands: [][]u8,

    pub fn init(gpa: std.mem.Allocator, view: schema.ImportHistoryView) !*ImportBatch {
        const batch = try gpa.create(ImportBatch);
        errdefer gpa.destroy(batch);
        const seed_low = std.hash.Wyhash.hash(0x74656c6172_696d70, view.source);
        const seed_high = std.hash.Wyhash.hash(seed_low, view.source);
        var session_id: SessionId = undefined;
        std.mem.writeInt(u64, session_id[0..8], seed_low, .little);
        std.mem.writeInt(u64, session_id[8..16], seed_high, .little);
        // Masked to stay positive as SQLite's i64; bit zero keeps it nonzero.
        const synthetic = (seed_low & ((@as(u64, 1) << 62) - 1)) | 1;

        const source = try gpa.dupe(u8, view.source);
        errdefer gpa.free(source);
        const times = try gpa.alloc(i64, view.entry_count);
        errdefer gpa.free(times);
        const commands = try gpa.alloc([]u8, view.entry_count);
        var copied: usize = 0;
        errdefer {
            for (commands[0..copied]) |command| gpa.free(command);
            gpa.free(commands);
        }
        var iterator = view.entries();
        var first_time: i64 = 0;
        while (try iterator.next()) |entry| {
            times[copied] = entry.started_at_ms;
            if (copied == 0) {
                first_time = entry.started_at_ms;
            }

            commands[copied] = try gpa.dupe(u8, entry.command);
            copied += 1;
        }
        if (copied != view.entry_count) {
            return error.InvalidImportBatch;
        }

        batch.* = .{
            .session_id = session_id,
            .pane_id = @enumFromInt(synthetic),
            .location = .{
                .workspace = .{ .workspace = @enumFromInt(synthetic) },
                .tab_id = @enumFromInt(synthetic),
            },
            .base_sequence = view.base_sequence,
            .started_at_ms = first_time,
            .source = source,
            .times = times,
            .commands = commands,
        };
        return batch;
    }

    pub fn deinit(batch: *ImportBatch, gpa: std.mem.Allocator) void {
        for (batch.commands) |command| gpa.free(command);
        gpa.free(batch.commands);
        gpa.free(batch.times);
        gpa.free(batch.source);
        gpa.destroy(batch);
    }
};

pub const Entry = struct {
    id: u64,
    pane_id: schema.PaneId,
    started_at_ms: i64,
    duration_ns: i64,
    exit_code: ?i32,
    status: CommandStatus,
    author: schema.HistoryAuthor,
    origin: schema.HistoryOrigin = .pane,
    command: []u8,
    cwd: []u8,
    workspace_path: []u8,
    provider: []u8 = &.{},

    pub fn deinit(entry: *Entry, gpa: std.mem.Allocator) void {
        gpa.free(entry.command);
        gpa.free(entry.cwd);
        gpa.free(entry.workspace_path);
        gpa.free(entry.provider);
    }
};

pub const QueryResult = struct {
    request_id: schema.RequestId,
    origin: QueryOrigin,
    entries: []Entry,
    gpa: std.mem.Allocator,

    pub fn deinit(result: *QueryResult) void {
        for (result.entries) |*entry| entry.deinit(result.gpa);
        result.gpa.free(result.entries);
        result.gpa.destroy(result);
    }
};

pub const Failure = struct {
    request_id: schema.RequestId,
    origin: QueryOrigin,
    message: []const u8,
};

pub const Response = union(enum) {
    query_result: *QueryResult,
    failed: Failure,
    pruned: Pruned,
    output_result: *OutputResult,
    stats_result: *StatsResult,
};

/// Owned captured-output read result.
pub const OutputResult = struct {
    request_id: schema.RequestId,
    origin: QueryOrigin,
    id: u64,
    truncated: bool,
    observed_bytes: u64,
    content: []u8,
    gpa: std.mem.Allocator,

    pub fn deinit(result: *OutputResult) void {
        result.gpa.free(result.content);
        result.gpa.destroy(result);
    }
};

pub fn deinitRequest(request: Request, gpa: std.mem.Allocator) void {
    switch (request) {
        .launch_attempt => |value| value.deinit(gpa),
        .session_started => |value| value.deinit(gpa),
        .command_finished => |value| value.deinit(gpa),
        .import => |value| value.deinit(gpa),
        .session_finished, .session_title, .query, .delete, .prune, .read_output, .stats => {},
    }
}

pub fn deinitResponse(response: Response, _: std.mem.Allocator) void {
    switch (response) {
        .query_result => |value| value.deinit(),
        .failed, .pruned => {},
        .output_result => |value| value.deinit(),
        .stats_result => |value| value.deinit(),
    }
}
