const std = @import("std");
const core = @import("telar-core");
const protocol = @import("protocol.zig");
const Transcript = @import("Transcript.zig");
const PendingApproval = @import("PendingApproval.zig");
const Command = @import("command.zig").Command;
const Prompt = @import("Prompt.zig");
const model_catalog = @import("model_catalog.zig");
const Codex = @This();

transcript: Transcript,
metadata: @import("ThreadMetadata.zig") = .{},
children: @import("ChildAgents.zig") = .{},
plan_identity: u64 = 0,
cwd: []const u8,
thread_id: [128]u8 = undefined,
thread_id_len: u8 = 0,
turn_id: [128]u8 = undefined,
turn_id_len: u8 = 0,
completed_turn_id: [128]u8 = undefined,
completed_turn_id_len: u8 = 0,
next_request: u64 = 3,
pending_turn_request: ?u64 = null,
pending_resume_request: ?u64 = null,
resume_target: core.RecentConversation = .{},
pending_options: ?core.AgentOptions = null,
skills: @import("SkillCatalog.zig") = .{},
skills_request: ?u64 = null,
command_request: ?u64 = null,
command_kind: core.AgentCommand.Kind = .clear,
command_name: [core.max_agent_session_title_bytes]u8 = undefined,
command_name_len: u8 = 0,
catalog_loaded: bool = false,
catalog_default: u8 = 0,
interrupt_pending: bool = false,
prompt_identity: u64 = 0,
next_approval: u64 = 1,
approvals: [protocol.max_approvals]PendingApproval = undefined,
approval_count: u8 = 0,
write_buffer: [protocol.max_write_bytes]u8 = undefined,

/// Example: `try transport.write(try codex.initialize());`
pub fn initialize(codex: *Codex) ![]const u8 {
    return protocol.encode(&codex.write_buffer, .{
        .id = 1,
        .method = "initialize",
        .params = .{
            .clientInfo = .{ .name = "telar", .title = "Telar", .version = "0.1.0" },
            .capabilities = .{
                .experimentalApi = true,
            },
        },
    });
}

/// Applies one bounded, parsed server record and returns any reply to write.
/// Example: `if (try codex.receive(.{ .value = parsed.value })) |reply| try transport.write(reply);`
pub fn receive(codex: *Codex, frame: @import("ProviderFrame.zig")) !?[]const u8 {
    const value = frame.value;
    if (value != .object) {
        return error.InvalidProviderFrame;
    }

    const method = protocol.field(value, "method");
    const id = protocol.field(value, "id");
    if (frame.truncated and (id != .null or method != .string)) {
        return error.ProviderControlTooLarge;
    }

    if (method == .string) {
        if (id != .null) {
            return codex.serverRequest(value);
        }

        if (std.mem.eql(u8, method.string, "skills/changed") and codex.skills_request == null) {
            const request = codex.allocateRequest();
            codex.skills_request = request;
            return try protocol.encode(
                &codex.write_buffer,
                .{
                    .id = request,
                    .method = "skills/list",
                    .params = .{
                        .cwds = .{codex.cwd},
                        .forceReload = true,
                    },
                },
            );
        }
        try codex.notification(frame);
        return codex.takeInterrupt();
    }

    if (id != .integer or id.integer < 0) {
        return error.InvalidProviderFrame;
    }

    const request_id: u64 = @intCast(id.integer);
    const failure = protocol.field(value, "error");
    if (failure != .null) {
        if (codex.skills_request == request_id) {
            codex.skills_request = null;
            codex.skills.value.phase = .failed;
            codex.skills.value.revision +%= 1;
            codex.transcript.value.skills = codex.skills.value;
            return null;
        }
        if (request_id == skills_request_id) {
            return null;
        }
        if (codex.command_request == request_id) {
            codex.command_request = null;
            codex.pending_options = null;
            codex.transcript.value.status = .ready;
            codex.errorMessage(protocol.string(protocol.field(failure, "message")));
            return null;
        }
        if (request_id == recent_request_id) {
            codex.transcript.value.recent.phase = .failed;
            return null;
        }
        if (codex.pending_resume_request == request_id) {
            if (request_id == 2) {
                return error.ProviderInitializationFailed;
            }

            codex.pending_resume_request = null;
            codex.transcript.value.status = .ready;
            codex.errorMessage(protocol.string(protocol.field(failure, "message")));
            return null;
        }

        if (request_id <= 2) {
            codex.fail(protocol.string(protocol.field(failure, "message")));
            return error.ProviderInitializationFailed;
        }

        if (codex.pending_turn_request == request_id) {
            codex.pending_turn_request = null;
            codex.pending_options = null;
            codex.interrupt_pending = false;
            codex.transcript.value.status = .ready;
        }

        codex.errorMessage(protocol.string(protocol.field(failure, "message")));
        return null;
    }

    const result = protocol.field(value, "result");
    if (codex.skills_request == request_id) {
        codex.skills_request = null;
        codex.skills.load(result, codex.cwd) catch {
            codex.skills.value.phase = .failed;
        };
        codex.transcript.value.skills = codex.skills.value;
        return null;
    }
    if (request_id == skills_request_id) {
        return null;
    }
    if (codex.command_request == request_id) {
        try codex.finishCommand(result);
        return null;
    }

    if (request_id == recent_request_id) {
        if (codex.transcript.value.recent.phase != .loading or codex.transcript.value.resumed) {
            return null;
        }

        @import("recent_conversations.zig").load(&codex.transcript.value, result, codex.cwd) catch {
            codex.transcript.value.recent.phase = .failed;
        };
        return null;
    }
    if (codex.pending_resume_request == request_id) {
        try codex.finishResume(result);
        return null;
    }

    if (request_id == 1 and codex.thread_id_len == 0) {
        var writer: std.Io.Writer = .fixed(&codex.write_buffer);
        try writer.writeAll("{\"method\":\"initialized\"}\n");
        try writer.print("{f}\n", .{std.json.fmt(.{
            .id = 0,
            .method = "model/list",
            .params = .{ .limit = core.agent_thread.max_models, .includeHidden = false },
        }, .{})});
        if (codex.resume_target.id_len != 0) {
            codex.pending_resume_request = 2;
            try writer.print("{f}\n", .{std.json.fmt(.{
                .id = 2,
                .method = "thread/resume",
                .params = .{ .threadId = codex.resume_target.idSlice(), .cwd = codex.cwd, .approvalPolicy = "untrusted", .approvalsReviewer = "user", .sandbox = "workspace-write", .excludeTurns = true },
            }, .{})});
        } else {
            try writer.print("{f}\n", .{std.json.fmt(.{
                .id = 2,
                .method = "thread/start",
                .params = .{ .cwd = codex.cwd, .approvalPolicy = "untrusted", .approvalsReviewer = "user", .sandbox = "workspace-write", .historyMode = "paginated" },
            }, .{})});
        }
        try writer.print("{f}\n", .{std.json.fmt(.{
            .id = recent_request_id,
            .method = "thread/list",
            .params = .{ .cwd = codex.cwd, .limit = core.RecentConversations.capacity, .sortKey = "updated_at", .sortDirection = "desc", .sourceKinds = .{ "cli", "vscode", "appServer", "exec" }, .archived = false },
        }, .{})});
        try writer.print("{f}\n", .{std.json.fmt(.{ .id = skills_request_id, .method = "skills/list", .params = .{ .cwds = .{codex.cwd}, .forceReload = false } }, .{})});
        codex.skills_request = skills_request_id;
        return writer.buffered();
    }

    if (request_id == 0 and !codex.catalog_loaded) {
        codex.catalog_default = try model_catalog.load(&codex.transcript.value, result);
        codex.catalog_loaded = true;
        if (protocol.string(protocol.field(result, "nextCursor")).len != 0) {
            codex.system("Codex has more models than this pane can display. This pane shows the first 16 models returned by Codex.");
        }

        try codex.finishStartup();
    } else if (request_id == 2 and codex.thread_id_len == 0) {
        const thread_id = protocol.string(protocol.field(protocol.field(result, "thread"), "id"));
        try copyId(&codex.thread_id, thread_id);
        codex.thread_id_len = @intCast(thread_id.len);
        codex.children.setRoot(thread_id);
        @memcpy(codex.transcript.value.thread_id[0..thread_id.len], thread_id);
        codex.transcript.value.thread_id_len = @intCast(thread_id.len);
        try codex.transcript.value.options.setModel(protocol.string(protocol.field(result, "model")));
        const effort = protocol.field(result, "reasoningEffort");
        if (effort != .null) {
            codex.transcript.value.options.effort = try core.AgentEffort.init(protocol.string(effort));
        }

        if (!protocol.is(protocol.field(result, "approvalPolicy"), "untrusted") or !protocol.is(protocol.field(result, "approvalsReviewer"), "user") or !protocol.is(protocol.field(protocol.field(result, "sandbox"), "type"), "workspaceWrite")) {
            return error.UnexpectedProviderPermissions;
        }

        codex.observeName(protocol.field(result, "thread"), "name");

        try codex.finishStartup();
    } else if (codex.pending_turn_request == request_id) {
        codex.pending_turn_request = null;
        try codex.startTurn(protocol.field(result, "turn"));
    }

    return codex.takeInterrupt();
}

/// Sends only valid actions for the current thread and approval generation.
/// Example: `if (try codex.command(.interrupt)) |line| try transport.write(line);`
pub fn command(codex: *Codex, value: Command) !?[]const u8 {
    switch (value) {
        .resume_conversation => |target| {
            if (!codex.transcript.value.canResume() or codex.pending_resume_request != null) {
                return null;
            }

            codex.resume_target = target;
            const request = codex.allocateRequest();
            codex.pending_resume_request = request;
            codex.transcript.value.status = .starting;
            return try protocol.encode(&codex.write_buffer, .{
                .id = request,
                .method = "thread/resume",
                .params = .{ .threadId = target.idSlice(), .cwd = codex.cwd, .approvalPolicy = "untrusted", .approvalsReviewer = "user", .sandbox = "workspace-write", .excludeTurns = true },
            });
        },
        .prompt => |prompt| {
            if (if (prompt.images.count == 0) core.AgentCommand.parse(prompt.bytes[0..prompt.len]) else null) |action| {
                return codex.runCommand(action, prompt.options);
            }
            codex.transcript.turn_identity = std.math.add(u64, codex.transcript.turn_identity, 1) catch return error.TurnIdentityExhausted;
            codex.plan_identity = 0;
            codex.prompt_identity = codex.transcript.next_identity;
            var preview: [core.agent_thread.max_prompt_bytes + 64]u8 = undefined;
            codex.transcript.update(.{ .role = .user, .text = prompt.preview(&preview), .complete = true });
            if (codex.transcript.value.status != .ready) {
                codex.system("Wait for the current turn to finish before sending another message.");
                return null;
            }

            if (!codex.transcript.value.accepts(prompt.options)) {
                codex.system("The selected model or reasoning effort is unavailable. Choose from the current Codex model catalog.");
                return null;
            }

            const request_id = codex.allocateRequest();
            codex.pending_turn_request = request_id;
            codex.pending_options = prompt.options;
            codex.transcript.value.status = .working;
            const encoded = switch (prompt.options.access) {
                .read_only => codex.encodeTurn(prompt, .{ .type = "readOnly", .networkAccess = false }),
                .workspace => codex.encodeTurn(prompt, .{ .type = "workspaceWrite", .writableRoots = [0][]const u8{}, .networkAccess = false, .excludeTmpdirEnvVar = false, .excludeSlashTmp = false }),
                .full_access => codex.encodeTurn(prompt, .{ .type = "dangerFullAccess" }),
            } catch |err| {
                if (err != error.WriteFailed) {
                    return err;
                }

                codex.pending_turn_request = null;
                codex.pending_options = null;
                codex.transcript.value.status = .ready;
                codex.system("This message and its skill references exceed the request limit. Send fewer skills or a shorter message.");
                return null;
            };
            return encoded;
        },
        .interrupt => {
            codex.interrupt_pending = codex.turn_id_len != 0 or codex.pending_turn_request != null;
            return codex.takeInterrupt();
        },
        .approval => |decision| {
            for (codex.approvals[0..codex.approval_count], 0..) |*approval, index| {
                if (approval.value.id != decision.id) {
                    continue;
                }

                var writer: std.Io.Writer = .fixed(&codex.write_buffer);
                try writer.print("{{\"id\":{s},\"result\":{{\"decision\":\"{s}\"}}}}\n", .{
                    approval.rpc_id[0..approval.rpc_id_len],
                    if (decision.accepted) @as([]const u8, "accept") else "decline",
                });
                codex.removeApproval(index);
                return writer.buffered();
            }

            return null;
        },
    }
}

/// Example: `codex.fail("Codex app-server disconnected.");`
pub fn fail(codex: *Codex, message: []const u8) void {
    codex.transcript.value.status = .failed;
    codex.approval_count = 0;
    codex.transcript.value.pending_approval = null;
    for (codex.transcript.value.item_storage[0..codex.transcript.value.item_count]) |*entry| {
        if (entry.status == .running or entry.status == .pending) {
            entry.status = .failed;
            entry.complete = true;
        }
    }

    codex.errorMessage(message);
}

fn errorMessage(codex: *Codex, message: []const u8) void {
    codex.transcript.update(.{ .role = .system, .kind = .system, .status = .failed, .title = "Error", .text = if (message.len == 0) "Codex reported an error." else message, .complete = true });
}

fn system(codex: *Codex, message: []const u8) void {
    codex.transcript.update(.{ .role = .system, .text = if (message.len == 0) "Codex reported an error." else message, .complete = true });
}

fn thread(codex: *const Codex) []const u8 {
    return codex.thread_id[0..codex.thread_id_len];
}

fn allocateRequest(codex: *Codex) u64 {
    while (codex.next_request == recent_request_id or codex.next_request == skills_request_id) {
        codex.next_request += 1;
    }

    const id = codex.next_request;
    codex.next_request += 1;
    return id;
}

fn finishStartup(codex: *Codex) !void {
    if (!codex.catalog_loaded or codex.thread_id_len == 0) {
        return;
    }

    const value = &codex.transcript.value;
    const model = value.findModel(value.options.modelSlice()) orelse selected: {
        const available = &value.model_storage[codex.catalog_default];
        var storage: [512]u8 = undefined;
        const notice = try std.fmt.bufPrint(&storage, "Configured model '{s}' is absent from Codex's current catalog. The next turn will use '{s}' with effort '{s}'.", .{ value.options.modelSlice(), available.idSlice(), available.default_effort.idSlice() });
        try value.options.setModel(available.idSlice());
        value.options.effort = available.default_effort;
        codex.system(notice);
        break :selected available;
    };
    if (value.options.effort.id_len == 0) {
        value.options.effort = model.default_effort;
    } else if (!model.supports(value.options.effort)) {
        var storage: [512]u8 = undefined;
        const notice = try std.fmt.bufPrint(&storage, "Configured effort '{s}' is unavailable for '{s}' in Codex's current catalog. The next turn will use '{s}'.", .{ value.options.effort.idSlice(), model.idSlice(), model.default_effort.idSlice() });
        value.options.effort = model.default_effort;
        codex.system(notice);
    }

    if (!value.accepts(value.options)) {
        return error.InvalidProviderModelCatalog;
    }

    value.status = .ready;
}

fn encodeTurn(codex: *Codex, prompt: Prompt, sandbox_policy: anytype) ![]const u8 {
    return protocol.encode(&codex.write_buffer, .{
        .id = codex.pending_turn_request.?,
        .method = "turn/start",
        .params = .{
            .threadId = codex.thread(),
            .input = @import("PromptInputs.zig"){ .text = prompt.bytes[0..prompt.len], .skills = &codex.skills, .images = &prompt.images },
            .model = prompt.options.modelSlice(),
            .effort = prompt.options.effort.idSlice(),
            .approvalPolicy = if (prompt.options.access == .full_access) @as([]const u8, "never") else "untrusted",
            .approvalsReviewer = "user",
            .sandboxPolicy = sandbox_policy,
        },
    });
}

fn runCommand(codex: *Codex, action: core.AgentCommand, options: core.AgentOptions) !?[]const u8 {
    if (codex.transcript.value.status != .ready or codex.command_request != null) {
        return null;
    }
    switch (action.kind) {
        .rename => {
            core.validateSessionTitle(action.argument) catch {
                codex.errorMessage("Use /rename followed by a conversation name (up to 96 bytes).");
                return null;
            };
            @memcpy(codex.command_name[0..action.argument.len], action.argument);
            codex.command_name_len = @intCast(action.argument.len);
        },
        .clear => {
            if (action.argument.len != 0) {
                codex.errorMessage("Use /clear without arguments to start a new conversation.");
                return null;
            }
        },
        else => {
            codex.errorMessage("Use the composer selector for this command.");
            return null;
        },
    }

    const request = codex.allocateRequest();
    codex.command_request = request;
    codex.command_kind = action.kind;
    codex.transcript.value.status = .starting;
    if (action.kind == .rename) {
        return try protocol.encode(&codex.write_buffer, .{ .id = request, .method = "thread/name/set", .params = .{ .threadId = codex.thread(), .name = action.argument } });
    }

    codex.pending_options = options;
    return try protocol.encode(&codex.write_buffer, .{
        .id = request,
        .method = "thread/start",
        .params = .{
            .cwd = codex.cwd,
            .model = options.modelSlice(),
            .config = .{ .model_reasoning_effort = options.effort.idSlice() },
            .approvalPolicy = if (options.access == .full_access) @as([]const u8, "never") else "untrusted",
            .approvalsReviewer = "user",
            .sandbox = switch (options.access) {
                .read_only => @as([]const u8, "read-only"),
                .workspace => "workspace-write",
                .full_access => "danger-full-access",
            },
            .historyMode = "paginated",
        },
    });
}

fn finishCommand(codex: *Codex, result: std.json.Value) !void {
    if (codex.command_kind == .rename) {
        codex.metadata.applyName(.{ .string = codex.command_name[0..codex.command_name_len] });
        codex.command_request = null;
        codex.transcript.value.status = .ready;
        return;
    }

    const options = codex.pending_options orelse return error.InvalidProviderFrame;
    const thread_value = protocol.field(result, "thread");
    const id = protocol.string(protocol.field(thread_value, "id"));
    if (id.len == 0 or std.mem.eql(u8, id, codex.thread())) {
        return error.InvalidProviderFrame;
    }
    const cwd = protocol.field(thread_value, "cwd");
    if (cwd != .null and !protocol.is(cwd, codex.cwd)) {
        return error.InvalidProviderFrame;
    }
    const policy: []const u8 = if (options.access == .full_access) "never" else "untrusted";
    const sandbox: []const u8 = switch (options.access) {
        .read_only => "readOnly",
        .workspace => "workspaceWrite",
        .full_access => "dangerFullAccess",
    };
    if (!protocol.is(protocol.field(result, "approvalPolicy"), policy) or !protocol.is(protocol.field(result, "approvalsReviewer"), "user") or !protocol.is(protocol.field(protocol.field(result, "sandbox"), "type"), sandbox)) {
        return error.UnexpectedProviderPermissions;
    }

    try copyId(&codex.thread_id, id);
    codex.thread_id_len = @intCast(id.len);
    const value = &codex.transcript.value;
    @memcpy(value.thread_id[0..id.len], id);
    value.thread_id_len = @intCast(id.len);
    value.current_turn_id_len = 0;
    value.item_count = 0;
    value.text_len = 0;
    value.metadata_len = 0;
    value.truncated = false;
    value.resumed = false;
    value.pending_approval = null;
    value.options = options;
    try value.options.setModel(protocol.string(protocol.field(result, "model")));
    const effort = protocol.field(result, "reasoningEffort");
    if (effort != .null) {
        value.options.effort = try core.AgentEffort.init(protocol.string(effort));
    }

    codex.transcript.id_lengths = @splat(0);
    codex.transcript.truncated_items = @splat(false);
    codex.turn_id_len = 0;
    codex.completed_turn_id_len = 0;
    codex.children = .{};
    codex.children.setRoot(id);
    codex.metadata.applyName(protocol.field(thread_value, "name"));
    codex.command_request = null;
    codex.pending_options = null;
    try codex.finishStartup();
}

fn startTurn(codex: *Codex, turn: std.json.Value) !void {
    const id = protocol.string(protocol.field(turn, "id"));
    try copyId(&codex.turn_id, id);
    codex.turn_id_len = @intCast(id.len);
    try codex.transcript.setTurn(id);
    if (codex.pending_options) |options| {
        codex.transcript.value.options = options;
        codex.pending_options = null;
    }

    codex.transcript.value.status = if (codex.approval_count == 0) .working else .blocked;
}

fn takeInterrupt(codex: *Codex) !?[]const u8 {
    if (!codex.interrupt_pending or codex.turn_id_len == 0) {
        return null;
    }

    codex.interrupt_pending = false;
    return try protocol.encode(&codex.write_buffer, .{
        .id = codex.allocateRequest(),
        .method = "turn/interrupt",
        .params = .{ .threadId = codex.thread(), .turnId = codex.turn_id[0..codex.turn_id_len] },
    });
}

fn observeName(codex: *Codex, object: std.json.Value, field: []const u8) void {
    if (object != .object) {
        return;
    }

    if (object.object.get(field)) |name| {
        codex.metadata.applyName(name);
    }
}

fn notification(codex: *Codex, frame: @import("ProviderFrame.zig")) !void {
    const method = protocol.string(protocol.field(frame.value, "method"));
    const params = protocol.field(frame.value, "params");
    if (std.mem.eql(u8, method, "thread/name/updated")) {
        if (codex.thread_id_len != 0 and protocol.is(protocol.field(params, "threadId"), codex.thread())) {
            codex.observeName(params, "threadName");
        }

        return;
    }

    if (std.mem.eql(u8, method, "thread/started")) {
        const started = protocol.field(params, "thread");
        if (codex.thread_id_len != 0 and protocol.is(protocol.field(started, "id"), codex.thread())) {
            codex.observeName(started, "name");
            return;
        }
    }

    if (codex.children.observe(&codex.transcript, .{ .method = method, .params = params })) {
        return;
    }

    const thread_id = protocol.field(params, "threadId");
    if (thread_id == .string and !std.mem.eql(u8, thread_id.string, codex.thread())) {
        return;
    }

    if (std.mem.startsWith(u8, method, "item/") and codex.turn_id_len == 0) {
        return;
    }

    const turn_id = protocol.field(params, "turnId");
    if (turn_id == .string and !std.mem.eql(u8, turn_id.string, codex.turn_id[0..codex.turn_id_len])) {
        return;
    }

    if (std.mem.eql(u8, method, "turn/started")) {
        const started_id = protocol.string(protocol.field(protocol.field(params, "turn"), "id"));
        if (std.mem.eql(u8, started_id, codex.completed_turn_id[0..codex.completed_turn_id_len]) or (codex.turn_id_len != 0 and !std.mem.eql(u8, started_id, codex.turn_id[0..codex.turn_id_len]))) {
            return;
        }
        if (codex.pending_turn_request == null and !protocol.is(protocol.field(protocol.field(params, "turn"), "id"), codex.turn_id[0..codex.turn_id_len])) {
            return;
        }
        try codex.startTurn(protocol.field(params, "turn"));
    } else if (std.mem.eql(u8, method, "turn/completed")) {
        const turn = protocol.field(params, "turn");
        if (codex.turn_id_len == 0 or !protocol.is(protocol.field(turn, "id"), codex.turn_id[0..codex.turn_id_len])) {
            return;
        }

        @memcpy(codex.completed_turn_id[0..codex.turn_id_len], codex.turn_id[0..codex.turn_id_len]);
        codex.completed_turn_id_len = codex.turn_id_len;
        codex.turn_id_len = 0;
        codex.transcript.value.current_turn_id_len = 0;
        codex.pending_turn_request = null;
        codex.interrupt_pending = false;
        codex.approval_count = 0;
        codex.transcript.value.pending_approval = null;
        codex.transcript.value.status = .ready;
        for (codex.transcript.value.item_storage[0..codex.transcript.value.item_count]) |*entry| {
            if (entry.turn_identity == codex.transcript.turn_identity and entry.kind != .subagent and !entry.complete) {
                entry.complete = true;
                entry.status = if (protocol.is(protocol.field(turn, "status"), "interrupted")) .interrupted else if (protocol.is(protocol.field(turn, "status"), "failed")) .failed else .completed;
            }
        }

        const failure = protocol.field(turn, "error");
        if (failure != .null) {
            codex.errorMessage(protocol.string(protocol.field(failure, "message")));
        } else if (protocol.is(protocol.field(turn, "status"), "interrupted")) {
            codex.system("Turn interrupted.");
        } else if (protocol.is(protocol.field(turn, "status"), "failed")) {
            codex.system("Codex could not complete this turn.");
        }
    } else if (std.mem.eql(u8, method, "serverRequest/resolved")) {
        var id_buffer: [1024]u8 = undefined;
        const id = try protocol.encode(&id_buffer, protocol.field(params, "requestId"));
        for (codex.approvals[0..codex.approval_count], 0..) |*approval, index| {
            if (std.mem.eql(u8, approval.rpc_id[0..approval.rpc_id_len], std.mem.trimEnd(u8, id, "\n"))) {
                codex.removeApproval(index);
                break;
            }
        }
    } else if (std.mem.eql(u8, method, "item/started") or std.mem.eql(u8, method, "item/completed")) {
        if (codex.turn_id_len == 0) {
            return;
        }
        const value = protocol.field(params, "item");
        var normalizer: @import("ItemNormalizer.zig") = .{};
        if (normalizer.item(value, std.mem.eql(u8, method, "item/completed"))) |normalized| {
            var update = normalized;
            update.truncated = update.truncated or frame.truncated;
            if (update.role == .user) {
                update.identity = codex.prompt_identity;
                update.complete = true;
            }

            codex.transcript.update(update);
        }

        codex.children.item(&codex.transcript, value);
    } else if (std.mem.eql(u8, method, "item/agentMessage/delta") or std.mem.eql(u8, method, "item/plan/delta")) {
        codex.transcript.update(.{
            .id = protocol.string(protocol.field(params, "itemId")),
            .role = .assistant,
            .kind = if (std.mem.eql(u8, method, "item/plan/delta")) .plan else .message,
            .text = protocol.string(protocol.field(params, "delta")),
            .append = true,
            .truncated = frame.truncated,
        });
    } else if (std.mem.eql(u8, method, "item/commandExecution/outputDelta")) {
        codex.transcript.update(.{
            .id = protocol.string(protocol.field(params, "itemId")),
            .role = .tool,
            .kind = .command,
            .text = protocol.string(protocol.field(params, "delta")),
            .append = true,
            .truncated = frame.truncated,
        });
    } else if (std.mem.eql(u8, method, "item/reasoning/summaryTextDelta")) {
        codex.transcript.update(.{
            .id = protocol.string(protocol.field(params, "itemId")),
            .role = .assistant,
            .kind = .reasoning,
            .title = "Reasoning summary",
            .text = protocol.string(protocol.field(params, "delta")),
            .append = true,
            .truncated = frame.truncated,
        });
    } else if (std.mem.eql(u8, method, "item/mcpToolCall/progress")) {
        codex.transcript.update(.{
            .id = protocol.string(protocol.field(params, "itemId")),
            .role = .tool,
            .kind = .mcp,
            .detail = protocol.string(protocol.field(params, "message")),
            .retain_text = true,
        });
    } else if (std.mem.eql(u8, method, "turn/plan/updated")) {
        codex.updatePlan(params);
    } else if (std.mem.eql(u8, method, "error")) {
        codex.errorMessage(protocol.string(protocol.field(protocol.field(params, "error"), "message")));
    }
}

fn updatePlan(codex: *Codex, params: std.json.Value) void {
    const steps = protocol.field(params, "plan");
    if (steps != .array) {
        return;
    }
    var buffer: [16 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var truncated = false;
    var completed = true;
    for (steps.array.items) |step| {
        const status = protocol.field(step, "status");
        const done = protocol.is(status, "completed");
        completed = completed and done;
        writer.print("[{s}] {s}\n", .{ if (done) @as([]const u8, "x") else if (protocol.is(status, "inProgress")) ">" else " ", protocol.string(protocol.field(step, "step")) }) catch {
            truncated = true;
            break;
        };
    }

    const retained = codex.transcript.get(codex.plan_identity) != null;
    const next_identity = codex.transcript.next_identity;
    codex.transcript.update(.{
        .identity = codex.plan_identity,
        .role = .assistant,
        .kind = .plan,
        .title = "Plan",
        .detail = protocol.string(protocol.field(params, "explanation")),
        .text = writer.buffered(),
        .truncated = truncated,
        .complete = completed,
    });
    if (!retained) {
        codex.plan_identity = if (codex.transcript.get(next_identity) != null) next_identity else 0;
    }
}

fn serverRequest(codex: *Codex, value: std.json.Value) !?[]const u8 {
    const method = protocol.field(value, "method");
    const id = protocol.field(value, "id");
    if (id != .integer and id != .string) {
        return error.InvalidProviderRequest;
    }

    const params = protocol.field(value, "params");
    const command_request = protocol.is(method, "item/commandExecution/requestApproval");
    const file_request = protocol.is(method, "item/fileChange/requestApproval");
    if (!command_request and !file_request) {
        codex.system("Codex requested an interaction that this agent pane does not support yet.");
        return try protocol.encode(&codex.write_buffer, .{ .id = id, .@"error" = .{ .code = -32601, .message = "This Telar client does not support this server request" } });
    }

    if (!protocol.is(protocol.field(params, "threadId"), codex.thread()) or
        !protocol.is(protocol.field(params, "turnId"), codex.turn_id[0..codex.turn_id_len]))
    {
        return try protocol.encode(&codex.write_buffer, .{ .id = id, .result = .{ .decision = "decline" } });
    }

    if (codex.approval_count == protocol.max_approvals) {
        return error.TooManyApprovalRequests;
    }

    var approval: PendingApproval = .{ .value = .{ .id = codex.next_approval, .kind = if (command_request) .command else .file_change } };
    const encoded_id = try protocol.encode(&approval.rpc_id, id);
    approval.rpc_id_len = @intCast(encoded_id.len - 1);
    const description: @import("ApprovalDescription.zig") = .{ .params = params, .transcript = &codex.transcript, .command_request = command_request };
    description.write(&approval.value) catch |err| return if (err == error.WriteFailed) error.ApprovalDescriptionTooLarge else err;
    codex.transcript.update(.{ .role = .system, .text = approval.value.text(), .complete = true });
    codex.approvals[codex.approval_count] = approval;
    codex.approval_count += 1;
    codex.next_approval += 1;
    codex.transcript.value.status = .blocked;
    codex.transcript.value.pending_approval = codex.approvals[0].value;
    return null;
}

fn removeApproval(codex: *Codex, index: usize) void {
    std.mem.copyForwards(PendingApproval, codex.approvals[index .. codex.approval_count - 1], codex.approvals[index + 1 .. codex.approval_count]);
    codex.approval_count -= 1;
    codex.transcript.value.pending_approval = if (codex.approval_count == 0) null else codex.approvals[0].value;
    codex.transcript.value.status = if (codex.approval_count == 0) .working else .blocked;
}

fn copyId(output: []u8, value: []const u8) !void {
    if (value.len == 0 or value.len > output.len or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) {
        return error.InvalidProviderId;
    }

    @memcpy(output[0..value.len], value);
}

const skills_request_id: u64 = 2147483646;
const recent_request_id = 2147483647;

fn finishResume(codex: *Codex, result: std.json.Value) !void {
    const thread_value = protocol.field(result, "thread");
    const id = protocol.string(protocol.field(thread_value, "id"));
    if (!std.mem.eql(u8, id, codex.resume_target.idSlice()) or !protocol.is(protocol.field(thread_value, "cwd"), codex.cwd)) {
        return error.InvalidResumedConversation;
    }
    if (!protocol.is(protocol.field(result, "approvalPolicy"), "untrusted") or !protocol.is(protocol.field(result, "approvalsReviewer"), "user") or !protocol.is(protocol.field(protocol.field(result, "sandbox"), "type"), "workspaceWrite")) {
        return error.UnexpectedProviderPermissions;
    }
    if (protocol.is(protocol.field(protocol.field(thread_value, "status"), "type"), "active")) {
        return error.ResumedConversationBusy;
    }

    var options: core.AgentOptions = .{};
    try options.setModel(protocol.string(protocol.field(result, "model")));
    const effort = protocol.field(result, "reasoningEffort");
    if (effort != .null) {
        options.effort = try core.AgentEffort.init(protocol.string(effort));
    }

    const previous = &codex.transcript.value;
    const pane_id = previous.pane_id;
    const generation = previous.pane_generation;
    const revision = previous.revision;
    const models = previous.model_storage;
    const model_count = previous.model_count;
    codex.transcript = .{ .value = .{ .pane_id = pane_id, .pane_generation = generation, .revision = revision, .options = options, .model_storage = models, .model_count = model_count, .skills = codex.skills.value, .resumed = true, .truncated = true, .recent = .{ .phase = .ready } } };
    try copyId(&codex.thread_id, id);
    codex.thread_id_len = @intCast(id.len);
    @memcpy(codex.transcript.value.thread_id[0..id.len], id);
    codex.transcript.value.thread_id_len = @intCast(id.len);
    codex.children = .{};
    codex.children.setRoot(id);
    const name = protocol.string(protocol.field(thread_value, "name"));
    codex.metadata.applyName(.{ .string = if (name.len != 0) name else codex.resume_target.titleSlice() });
    codex.pending_resume_request = null;
    try codex.finishStartup();
}

/// Expires optional listing independently; a timed-out resume fails explicitly.
/// Example: `try codex.expireResume();`
pub fn expireResume(codex: *Codex) !void {
    if (codex.pending_resume_request != null) {
        return error.ProviderResumeTimeout;
    }
}
