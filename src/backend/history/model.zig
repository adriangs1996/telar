//! Owned values exchanged with the history worker.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;

pub const max_query_bytes = schema.max_history_query_bytes;
pub const max_results = schema.max_history_results;
pub const max_result_payload_bytes = core.transport.max_frame_size;
pub const encoded_result_header_bytes = 11;
pub const encoded_entry_overhead_bytes = 46;

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
    id: SessionId,
    title: [schema.max_agent_session_title_bytes]u8 = undefined,
    title_len: u8 = 0,
    source: schema.AgentTitleSource,
    state: schema.AgentTitleState,

    pub fn init(
        id: SessionId,
        title_value: []const u8,
        source: schema.AgentTitleSource,
        state: schema.AgentTitleState,
    ) !SessionTitle {
        if (title_value.len > schema.max_agent_session_title_bytes)
            return error.AgentTitleTooLong;
        if (!std.unicode.utf8ValidateSlice(title_value)) return error.InvalidAgentTitle;
        for (title_value) |byte| if (byte < 0x20 or byte == 0x7f)
            return error.InvalidAgentTitle;
        switch (source) {
            .telar => if (state == .ready) return error.InvalidAgentTitle,
            .generated, .manual => if (state != .ready or title_value.len == 0)
                return error.InvalidAgentTitle,
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
    _ = try SessionTitle.init(session_id, "Improve sidebar", .generated, .ready);
    _ = try SessionTitle.init(session_id, "", .telar, .failed);
    try std.testing.expectError(
        error.InvalidAgentTitle,
        SessionTitle.init(session_id, "bad\ntitle", .generated, .ready),
    );
    try std.testing.expectError(
        error.InvalidAgentTitle,
        SessionTitle.init(session_id, "", .generated, .ready),
    );
    try std.testing.expectError(
        error.InvalidAgentTitle,
        SessionTitle.init(session_id, "manual", .manual, .pending),
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
    cols: u16,
    rows: u16,
    command: []u8,
    cwd: []u8,
    workspace_path: []u8,
    command_truncated: bool,

    pub fn deinit(value: *CommandFinished, gpa: std.mem.Allocator) void {
        const allocation_len = @sizeOf(CommandFinished) + value.command.len +
            value.cwd.len + value.workspace_path.len;
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
    request_id: schema.RequestId,
    origin: QueryOrigin,
    text: [max_query_bytes]u8 = undefined,
    text_len: u16 = 0,
    scope: Scope = .global,
    scope_text: [schema.max_cwd_bytes]u8 = undefined,
    scope_text_len: u16 = 0,
    pane_id: schema.PaneId = .invalid,
    failed_only: bool = false,
    limit: u16 = 20,

    pub fn init(
        request_id: schema.RequestId,
        origin: QueryOrigin,
        text_value: []const u8,
        scope: Scope,
        scope_value: []const u8,
        pane_id: schema.PaneId,
        failed_only: bool,
        limit: u16,
    ) !Query {
        if (text_value.len > max_query_bytes) return error.QueryTooLong;
        if (scope_value.len > schema.max_cwd_bytes) return error.ScopeTooLong;
        if (limit == 0 or limit > max_results) return error.InvalidLimit;
        if (scope == .pane and pane_id == .invalid) return error.InvalidPaneId;
        if (scope != .pane and pane_id != .invalid) return error.UnexpectedPaneId;

        var query: Query = .{
            .request_id = request_id,
            .origin = origin,
            .scope = scope,
            .pane_id = pane_id,
            .failed_only = failed_only,
            .limit = limit,
        };
        @memcpy(query.text[0..text_value.len], text_value);
        query.text_len = @intCast(text_value.len);
        @memcpy(query.scope_text[0..scope_value.len], scope_value);
        query.scope_text_len = @intCast(scope_value.len);
        return query;
    }

    pub fn textSlice(query: *const Query) []const u8 {
        return query.text[0..query.text_len];
    }

    pub fn scopeSlice(query: *const Query) []const u8 {
        return query.scope_text[0..query.scope_text_len];
    }
};

pub const Request = union(enum) {
    launch_attempt: *LaunchAttempt,
    session_started: *SessionStarted,
    session_finished: SessionFinished,
    session_title: SessionTitle,
    command_finished: *CommandFinished,
    query: Query,
};

pub const Entry = struct {
    id: u64,
    pane_id: schema.PaneId,
    started_at_ms: i64,
    duration_ns: i64,
    exit_code: ?i32,
    status: CommandStatus,
    command: []u8,
    cwd: []u8,
    workspace_path: []u8,

    pub fn deinit(entry: *Entry, gpa: std.mem.Allocator) void {
        gpa.free(entry.command);
        gpa.free(entry.cwd);
        gpa.free(entry.workspace_path);
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
};

pub fn deinitRequest(request: Request, gpa: std.mem.Allocator) void {
    switch (request) {
        .launch_attempt => |value| value.deinit(gpa),
        .session_started => |value| value.deinit(gpa),
        .command_finished => |value| value.deinit(gpa),
        .session_finished, .session_title, .query => {},
    }
}

pub fn deinitResponse(response: Response, _: std.mem.Allocator) void {
    switch (response) {
        .query_result => |value| value.deinit(),
        .failed => {},
    }
}
