const recent_conversations = @import("recent_conversations.zig");
const command_module = @import("command.zig");
const std = @import("std");
const core = @import("telar-core");
const protocol = @import("protocol.zig");
const Transcript = @import("Transcript.zig");
const PendingApproval = @import("PendingApproval.zig");
const Prompt = @import("Prompt.zig");
const model_catalog = @import("model_catalog.zig");
const ThreadMetadata = @import("ThreadMetadata.zig");
const ChildAgents = @import("ChildAgents.zig");
const SkillCatalog = @import("SkillCatalog.zig");
const ProviderFrame = @import("ProviderFrame.zig");
const PromptInputs = @import("PromptInputs.zig");
const ItemNormalizer = @import("ItemNormalizer.zig");
const ApprovalDescription = @import("ApprovalDescription.zig");
const Codex = @This();

transcript: Transcript,
metadata: ThreadMetadata = .{},
children: ChildAgents = .{},
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
skills: SkillCatalog = .{},
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
pub fn initialize(self: *Codex) ![]const u8 {
    return protocol.encode(&self.write_buffer, .{
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
pub fn receive(self: *Codex, frame: ProviderFrame) !?[]const u8 {
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
            return self.serverRequest(value);
        }

        if (std.mem.eql(u8, method.string, "skills/changed") and self.skills_request == null) {
            const request = self.allocateRequest();
            self.skills_request = request;
            return try protocol.encode(
                &self.write_buffer,
                .{
                    .id = request,
                    .method = "skills/list",
                    .params = .{
                        .cwds = .{self.cwd},
                        .forceReload = true,
                    },
                },
            );
        }
        try self.notification(frame);
        return self.takeInterrupt();
    }

    if (id != .integer or id.integer < 0) {
        return error.InvalidProviderFrame;
    }

    const request_id: u64 = @intCast(id.integer);
    const failure = protocol.field(value, "error");
    if (failure != .null) {
        if (self.skills_request == request_id) {
            self.skills_request = null;
            self.skills.value.phase = .failed;
            self.skills.value.revision +%= 1;
            self.transcript.value.skills = self.skills.value;
            return null;
        }
        if (request_id == skills_request_id) {
            return null;
        }
        if (self.command_request == request_id) {
            self.command_request = null;
            self.pending_options = null;
            self.transcript.value.status = .ready;
            self.errorMessage(protocol.string(protocol.field(failure, "message")));
            return null;
        }
        if (request_id == recent_request_id) {
            self.transcript.value.recent.phase = .failed;
            return null;
        }
        if (self.pending_resume_request == request_id) {
            if (request_id == 2) {
                return error.ProviderInitializationFailed;
            }

            self.pending_resume_request = null;
            self.transcript.value.status = .ready;
            self.errorMessage(protocol.string(protocol.field(failure, "message")));
            return null;
        }

        if (request_id <= 2) {
            self.fail(protocol.string(protocol.field(failure, "message")));
            return error.ProviderInitializationFailed;
        }

        if (self.pending_turn_request == request_id) {
            self.pending_turn_request = null;
            self.pending_options = null;
            self.interrupt_pending = false;
            self.transcript.value.status = .ready;
        }

        self.errorMessage(protocol.string(protocol.field(failure, "message")));
        return null;
    }

    const result = protocol.field(value, "result");
    if (self.skills_request == request_id) {
        self.skills_request = null;
        self.skills.load(result, self.cwd) catch {
            self.skills.value.phase = .failed;
        };
        self.transcript.value.skills = self.skills.value;
        return null;
    }
    if (request_id == skills_request_id) {
        return null;
    }
    if (self.command_request == request_id) {
        try self.finishCommand(result);
        return null;
    }

    if (request_id == recent_request_id) {
        if (self.transcript.value.recent.phase != .loading or self.transcript.value.resumed) {
            return null;
        }

        recent_conversations.load(&self.transcript.value, result, self.cwd) catch {
            self.transcript.value.recent.phase = .failed;
        };
        return null;
    }
    if (self.pending_resume_request == request_id) {
        try self.finishResume(result);
        return null;
    }

    if (request_id == 1 and self.thread_id_len == 0) {
        var writer: std.Io.Writer = .fixed(&self.write_buffer);
        try writer.writeAll("{\"method\":\"initialized\"}\n");
        try writer.print("{f}\n", .{std.json.fmt(.{
            .id = 0,
            .method = "model/list",
            .params = .{ .limit = core.agent_thread.max_models, .includeHidden = false },
        }, .{})});
        if (self.resume_target.id_len != 0) {
            self.pending_resume_request = 2;
            try writer.print("{f}\n", .{std.json.fmt(.{
                .id = 2,
                .method = "thread/resume",
                .params = .{ .threadId = self.resume_target.idSlice(), .cwd = self.cwd, .approvalPolicy = "untrusted", .approvalsReviewer = "user", .sandbox = "workspace-write", .excludeTurns = true },
            }, .{})});
        } else {
            try writer.print("{f}\n", .{std.json.fmt(.{
                .id = 2,
                .method = "thread/start",
                .params = .{ .cwd = self.cwd, .approvalPolicy = "untrusted", .approvalsReviewer = "user", .sandbox = "workspace-write", .historyMode = "paginated" },
            }, .{})});
        }
        try writer.print("{f}\n", .{std.json.fmt(.{
            .id = recent_request_id,
            .method = "thread/list",
            .params = .{ .cwd = self.cwd, .limit = core.RecentConversations.capacity, .sortKey = "updated_at", .sortDirection = "desc", .sourceKinds = .{ "cli", "vscode", "appServer", "exec" }, .archived = false },
        }, .{})});
        try writer.print("{f}\n", .{std.json.fmt(.{ .id = skills_request_id, .method = "skills/list", .params = .{ .cwds = .{self.cwd}, .forceReload = false } }, .{})});
        self.skills_request = skills_request_id;
        return writer.buffered();
    }

    if (request_id == 0 and !self.catalog_loaded) {
        self.catalog_default = try model_catalog.load(&self.transcript.value, result);
        self.catalog_loaded = true;
        if (protocol.string(protocol.field(result, "nextCursor")).len != 0) {
            self.system("Codex has more models than this pane can display. This pane shows the first 16 models returned by Codex.");
        }

        try self.finishStartup();
    } else if (request_id == 2 and self.thread_id_len == 0) {
        const thread_id = protocol.string(protocol.field(protocol.field(result, "thread"), "id"));
        try copyId(&self.thread_id, thread_id);
        self.thread_id_len = @intCast(thread_id.len);
        self.children.setRoot(thread_id);
        @memcpy(self.transcript.value.thread_id[0..thread_id.len], thread_id);
        self.transcript.value.thread_id_len = @intCast(thread_id.len);
        try self.transcript.value.options.setModel(protocol.string(protocol.field(result, "model")));
        const effort = protocol.field(result, "reasoningEffort");
        if (effort != .null) {
            self.transcript.value.options.effort = try core.AgentEffort.init(protocol.string(effort));
        }

        if (!protocol.is(protocol.field(result, "approvalPolicy"), "untrusted") or !protocol.is(protocol.field(result, "approvalsReviewer"), "user") or !protocol.is(protocol.field(protocol.field(result, "sandbox"), "type"), "workspaceWrite")) {
            return error.UnexpectedProviderPermissions;
        }

        self.observeName(protocol.field(result, "thread"), "name");

        try self.finishStartup();
    } else if (self.pending_turn_request == request_id) {
        self.pending_turn_request = null;
        try self.startTurn(protocol.field(result, "turn"));
    }

    return self.takeInterrupt();
}

/// Sends only valid actions for the current thread and approval generation.
/// Example: `if (try codex.command(.interrupt)) |line| try transport.write(line);`
pub fn command(self: *Codex, value: command_module.Command) !?[]const u8 {
    switch (value) {
        .resume_conversation => |target| {
            if (!self.transcript.value.canResume() or self.pending_resume_request != null) {
                return null;
            }

            self.resume_target = target;
            const request = self.allocateRequest();
            self.pending_resume_request = request;
            self.transcript.value.status = .starting;
            return try protocol.encode(&self.write_buffer, .{
                .id = request,
                .method = "thread/resume",
                .params = .{ .threadId = target.idSlice(), .cwd = self.cwd, .approvalPolicy = "untrusted", .approvalsReviewer = "user", .sandbox = "workspace-write", .excludeTurns = true },
            });
        },
        .prompt => |prompt| {
            if (if (prompt.images.count == 0) core.AgentCommand.parse(prompt.bytes[0..prompt.len]) else null) |action| {
                return self.runCommand(action, prompt.options);
            }
            self.transcript.turn_identity = std.math.add(u64, self.transcript.turn_identity, 1) catch return error.TurnIdentityExhausted;
            self.plan_identity = 0;
            self.prompt_identity = self.transcript.next_identity;
            var preview: [core.agent_thread.max_prompt_bytes + 64]u8 = undefined;
            self.transcript.update(.{ .role = .user, .text = prompt.preview(&preview), .complete = true });
            if (self.transcript.value.status != .ready) {
                self.system("Wait for the current turn to finish before sending another message.");
                return null;
            }

            if (!self.transcript.value.accepts(prompt.options)) {
                self.system("The selected model or reasoning effort is unavailable. Choose from the current Codex model catalog.");
                return null;
            }

            const request_id = self.allocateRequest();
            self.pending_turn_request = request_id;
            self.pending_options = prompt.options;
            self.transcript.value.status = .working;
            const encoded = switch (prompt.options.access) {
                .read_only => self.encodeTurn(prompt, .{ .type = "readOnly", .networkAccess = false }),
                .workspace => self.encodeTurn(prompt, .{ .type = "workspaceWrite", .writableRoots = [0][]const u8{}, .networkAccess = false, .excludeTmpdirEnvVar = false, .excludeSlashTmp = false }),
                .full_access => self.encodeTurn(prompt, .{ .type = "dangerFullAccess" }),
            } catch |err| {
                if (err != error.WriteFailed) {
                    return err;
                }

                self.pending_turn_request = null;
                self.pending_options = null;
                self.transcript.value.status = .ready;
                self.system("This message and its skill references exceed the request limit. Send fewer skills or a shorter message.");
                return null;
            };
            return encoded;
        },
        .interrupt => {
            self.interrupt_pending = self.turn_id_len != 0 or self.pending_turn_request != null;
            return self.takeInterrupt();
        },
        .approval => |decision| {
            for (self.approvals[0..self.approval_count], 0..) |*approval, index| {
                if (approval.value.id != decision.id) {
                    continue;
                }

                var writer: std.Io.Writer = .fixed(&self.write_buffer);
                try writer.print("{{\"id\":{s},\"result\":{{\"decision\":\"{s}\"}}}}\n", .{
                    approval.rpc_id[0..approval.rpc_id_len],
                    if (decision.accepted) @as([]const u8, "accept") else "decline",
                });
                self.removeApproval(index);
                return writer.buffered();
            }

            return null;
        },
    }
}

/// Example: `codex.fail("Codex app-server disconnected.");`
pub fn fail(self: *Codex, message: []const u8) void {
    self.transcript.value.status = .failed;
    self.approval_count = 0;
    self.transcript.value.pending_approval = null;
    for (self.transcript.value.item_storage[0..self.transcript.value.item_count]) |*entry| {
        if (entry.status == .running or entry.status == .pending) {
            entry.status = .failed;
            entry.complete = true;
        }
    }

    self.errorMessage(message);
}

fn errorMessage(self: *Codex, message: []const u8) void {
    self.transcript.update(.{ .role = .system, .kind = .system, .status = .failed, .title = "Error", .text = if (message.len == 0) "Codex reported an error." else message, .complete = true });
}

fn system(self: *Codex, message: []const u8) void {
    self.transcript.update(.{ .role = .system, .text = if (message.len == 0) "Codex reported an error." else message, .complete = true });
}

fn thread(self: *const Codex) []const u8 {
    return self.thread_id[0..self.thread_id_len];
}

fn allocateRequest(self: *Codex) u64 {
    while (self.next_request == recent_request_id or self.next_request == skills_request_id) {
        self.next_request += 1;
    }

    const id = self.next_request;
    self.next_request += 1;
    return id;
}

fn finishStartup(self: *Codex) !void {
    if (!self.catalog_loaded or self.thread_id_len == 0) {
        return;
    }

    const value = &self.transcript.value;
    const model = value.findModel(value.options.modelSlice()) orelse selected: {
        const available = &value.model_storage[self.catalog_default];
        var storage: [512]u8 = undefined;
        const notice = try std.fmt.bufPrint(&storage, "Configured model '{s}' is absent from Codex's current catalog. The next turn will use '{s}' with effort '{s}'.", .{ value.options.modelSlice(), available.idSlice(), available.default_effort.idSlice() });
        try value.options.setModel(available.idSlice());
        value.options.effort = available.default_effort;
        self.system(notice);
        break :selected available;
    };
    if (value.options.effort.id_len == 0) {
        value.options.effort = model.default_effort;
    } else if (!model.supports(value.options.effort)) {
        var storage: [512]u8 = undefined;
        const notice = try std.fmt.bufPrint(&storage, "Configured effort '{s}' is unavailable for '{s}' in Codex's current catalog. The next turn will use '{s}'.", .{ value.options.effort.idSlice(), model.idSlice(), model.default_effort.idSlice() });
        value.options.effort = model.default_effort;
        self.system(notice);
    }

    if (!value.accepts(value.options)) {
        return error.InvalidProviderModelCatalog;
    }

    value.status = .ready;
}

fn encodeTurn(self: *Codex, prompt: Prompt, sandbox_policy: anytype) ![]const u8 {
    return protocol.encode(&self.write_buffer, .{
        .id = self.pending_turn_request.?,
        .method = "turn/start",
        .params = .{
            .threadId = self.thread(),
            .input = PromptInputs{ .text = prompt.bytes[0..prompt.len], .skills = &self.skills, .images = &prompt.images },
            .model = prompt.options.modelSlice(),
            .effort = prompt.options.effort.idSlice(),
            .approvalPolicy = if (prompt.options.access == .full_access) @as([]const u8, "never") else "untrusted",
            .approvalsReviewer = "user",
            .sandboxPolicy = sandbox_policy,
        },
    });
}

fn runCommand(self: *Codex, action: core.AgentCommand, options: core.AgentOptions) !?[]const u8 {
    if (self.transcript.value.status != .ready or self.command_request != null) {
        return null;
    }
    switch (action.kind) {
        .rename => {
            core.validateSessionTitle(action.argument) catch {
                self.errorMessage("Use /rename followed by a conversation name (up to 96 bytes).");
                return null;
            };
            @memcpy(self.command_name[0..action.argument.len], action.argument);
            self.command_name_len = @intCast(action.argument.len);
        },
        .clear => {
            if (action.argument.len != 0) {
                self.errorMessage("Use /clear without arguments to start a new conversation.");
                return null;
            }
        },
        else => {
            self.errorMessage("Use the composer selector for this command.");
            return null;
        },
    }

    const request = self.allocateRequest();
    self.command_request = request;
    self.command_kind = action.kind;
    self.transcript.value.status = .starting;
    if (action.kind == .rename) {
        return try protocol.encode(&self.write_buffer, .{ .id = request, .method = "thread/name/set", .params = .{ .threadId = self.thread(), .name = action.argument } });
    }

    self.pending_options = options;
    return try protocol.encode(&self.write_buffer, .{
        .id = request,
        .method = "thread/start",
        .params = .{
            .cwd = self.cwd,
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

fn finishCommand(self: *Codex, result: std.json.Value) !void {
    if (self.command_kind == .rename) {
        self.metadata.applyName(.{ .string = self.command_name[0..self.command_name_len] });
        self.command_request = null;
        self.transcript.value.status = .ready;
        return;
    }

    const options = self.pending_options orelse return error.InvalidProviderFrame;
    const thread_value = protocol.field(result, "thread");
    const id = protocol.string(protocol.field(thread_value, "id"));
    if (id.len == 0 or std.mem.eql(u8, id, self.thread())) {
        return error.InvalidProviderFrame;
    }
    const cwd = protocol.field(thread_value, "cwd");
    if (cwd != .null and !protocol.is(cwd, self.cwd)) {
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

    try copyId(&self.thread_id, id);
    self.thread_id_len = @intCast(id.len);
    const value = &self.transcript.value;
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

    self.transcript.id_lengths = @splat(0);
    self.transcript.truncated_items = @splat(false);
    self.turn_id_len = 0;
    self.completed_turn_id_len = 0;
    self.children = .{};
    self.children.setRoot(id);
    self.metadata.review_latest_edition_id = 0;
    self.metadata.applyName(protocol.field(thread_value, "name"));
    self.command_request = null;
    self.pending_options = null;
    try self.finishStartup();
}

fn startTurn(self: *Codex, turn: std.json.Value) !void {
    const id = protocol.string(protocol.field(turn, "id"));
    try copyId(&self.turn_id, id);
    self.turn_id_len = @intCast(id.len);
    try self.transcript.setTurn(id);
    if (self.pending_options) |options| {
        self.transcript.value.options = options;
        self.pending_options = null;
    }

    self.transcript.value.status = if (self.approval_count == 0) .working else .blocked;
}

fn takeInterrupt(self: *Codex) !?[]const u8 {
    if (!self.interrupt_pending or self.turn_id_len == 0) {
        return null;
    }

    self.interrupt_pending = false;
    return try protocol.encode(&self.write_buffer, .{
        .id = self.allocateRequest(),
        .method = "turn/interrupt",
        .params = .{ .threadId = self.thread(), .turnId = self.turn_id[0..self.turn_id_len] },
    });
}

fn observeName(self: *Codex, object: std.json.Value, field: []const u8) void {
    if (object != .object) {
        return;
    }

    if (object.object.get(field)) |name| {
        self.metadata.applyName(name);
    }
}

fn notification(self: *Codex, frame: ProviderFrame) !void {
    const method = protocol.string(protocol.field(frame.value, "method"));
    const params = protocol.field(frame.value, "params");
    if (std.mem.eql(u8, method, "thread/name/updated")) {
        if (self.thread_id_len != 0 and protocol.is(protocol.field(params, "threadId"), self.thread())) {
            self.observeName(params, "threadName");
        }

        return;
    }

    if (std.mem.eql(u8, method, "thread/started")) {
        const started = protocol.field(params, "thread");
        if (self.thread_id_len != 0 and protocol.is(protocol.field(started, "id"), self.thread())) {
            self.observeName(started, "name");
            return;
        }
    }

    if (self.children.observe(&self.transcript, .{ .method = method, .params = params })) {
        return;
    }

    const thread_id = protocol.field(params, "threadId");
    if (thread_id == .string and !std.mem.eql(u8, thread_id.string, self.thread())) {
        return;
    }

    if (std.mem.startsWith(u8, method, "item/") and self.turn_id_len == 0) {
        return;
    }

    const turn_id = protocol.field(params, "turnId");
    if (turn_id == .string and !std.mem.eql(u8, turn_id.string, self.turn_id[0..self.turn_id_len])) {
        return;
    }

    if (std.mem.eql(u8, method, "turn/started")) {
        const started_id = protocol.string(protocol.field(protocol.field(params, "turn"), "id"));
        if (std.mem.eql(u8, started_id, self.completed_turn_id[0..self.completed_turn_id_len]) or (self.turn_id_len != 0 and !std.mem.eql(u8, started_id, self.turn_id[0..self.turn_id_len]))) {
            return;
        }
        if (self.pending_turn_request == null and !protocol.is(protocol.field(protocol.field(params, "turn"), "id"), self.turn_id[0..self.turn_id_len])) {
            return;
        }
        try self.startTurn(protocol.field(params, "turn"));
    } else if (std.mem.eql(u8, method, "turn/completed")) {
        const turn = protocol.field(params, "turn");
        if (self.turn_id_len == 0 or !protocol.is(protocol.field(turn, "id"), self.turn_id[0..self.turn_id_len])) {
            return;
        }

        @memcpy(self.completed_turn_id[0..self.turn_id_len], self.turn_id[0..self.turn_id_len]);
        self.completed_turn_id_len = self.turn_id_len;
        self.turn_id_len = 0;
        self.transcript.value.current_turn_id_len = 0;
        self.pending_turn_request = null;
        self.interrupt_pending = false;
        self.approval_count = 0;
        self.transcript.value.pending_approval = null;
        self.transcript.value.status = .ready;
        for (self.transcript.value.item_storage[0..self.transcript.value.item_count]) |*entry| {
            if (entry.turn_identity == self.transcript.turn_identity and entry.kind != .subagent and !entry.complete) {
                entry.complete = true;
                entry.status = if (protocol.is(protocol.field(turn, "status"), "interrupted")) .interrupted else if (protocol.is(protocol.field(turn, "status"), "failed")) .failed else .completed;
            }
        }

        const failure = protocol.field(turn, "error");
        if (failure != .null) {
            self.errorMessage(protocol.string(protocol.field(failure, "message")));
        } else if (protocol.is(protocol.field(turn, "status"), "interrupted")) {
            self.system("Turn interrupted.");
        } else if (protocol.is(protocol.field(turn, "status"), "failed")) {
            self.system("Codex could not complete this turn.");
        }
    } else if (std.mem.eql(u8, method, "serverRequest/resolved")) {
        var id_buffer: [1024]u8 = undefined;
        const id = try protocol.encode(&id_buffer, protocol.field(params, "requestId"));
        for (self.approvals[0..self.approval_count], 0..) |*approval, index| {
            if (std.mem.eql(u8, approval.rpc_id[0..approval.rpc_id_len], std.mem.trimEnd(u8, id, "\n"))) {
                self.removeApproval(index);
                break;
            }
        }
    } else if (std.mem.eql(u8, method, "item/started") or std.mem.eql(u8, method, "item/completed")) {
        if (self.turn_id_len == 0) {
            return;
        }
        const value = protocol.field(params, "item");
        var normalizer: ItemNormalizer = .{};
        if (normalizer.item(value, std.mem.eql(u8, method, "item/completed"))) |normalized| {
            var update = normalized;
            update.truncated = update.truncated or frame.truncated;
            if (update.role == .user) {
                update.identity = self.prompt_identity;
                update.complete = true;
            }

            self.transcript.update(update);
        }

        self.children.item(&self.transcript, value);
    } else if (std.mem.eql(u8, method, "item/agentMessage/delta") or std.mem.eql(u8, method, "item/plan/delta")) {
        self.transcript.update(.{
            .id = protocol.string(protocol.field(params, "itemId")),
            .role = .assistant,
            .kind = if (std.mem.eql(u8, method, "item/plan/delta")) .plan else .message,
            .text = protocol.string(protocol.field(params, "delta")),
            .append = true,
            .truncated = frame.truncated,
        });
    } else if (std.mem.eql(u8, method, "item/commandExecution/outputDelta")) {
        self.transcript.update(.{
            .id = protocol.string(protocol.field(params, "itemId")),
            .role = .tool,
            .kind = .command,
            .text = protocol.string(protocol.field(params, "delta")),
            .append = true,
            .truncated = frame.truncated,
        });
    } else if (std.mem.eql(u8, method, "item/reasoning/summaryTextDelta")) {
        self.transcript.update(.{
            .id = protocol.string(protocol.field(params, "itemId")),
            .role = .assistant,
            .kind = .reasoning,
            .title = "Reasoning summary",
            .text = protocol.string(protocol.field(params, "delta")),
            .append = true,
            .truncated = frame.truncated,
        });
    } else if (std.mem.eql(u8, method, "item/mcpToolCall/progress")) {
        self.transcript.update(.{
            .id = protocol.string(protocol.field(params, "itemId")),
            .role = .tool,
            .kind = .mcp,
            .detail = protocol.string(protocol.field(params, "message")),
            .retain_text = true,
        });
    } else if (std.mem.eql(u8, method, "turn/plan/updated")) {
        self.updatePlan(params);
    } else if (std.mem.eql(u8, method, "error")) {
        self.errorMessage(protocol.string(protocol.field(protocol.field(params, "error"), "message")));
    }
}

fn updatePlan(self: *Codex, params: std.json.Value) void {
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

    const retained = self.transcript.get(self.plan_identity) != null;
    const next_identity = self.transcript.next_identity;
    self.transcript.update(.{
        .identity = self.plan_identity,
        .role = .assistant,
        .kind = .plan,
        .title = "Plan",
        .detail = protocol.string(protocol.field(params, "explanation")),
        .text = writer.buffered(),
        .truncated = truncated,
        .complete = completed,
    });
    if (!retained) {
        self.plan_identity = if (self.transcript.get(next_identity) != null) next_identity else 0;
    }
}

fn serverRequest(self: *Codex, value: std.json.Value) !?[]const u8 {
    const method = protocol.field(value, "method");
    const id = protocol.field(value, "id");
    if (id != .integer and id != .string) {
        return error.InvalidProviderRequest;
    }

    const params = protocol.field(value, "params");
    const command_request = protocol.is(method, "item/commandExecution/requestApproval");
    const file_request = protocol.is(method, "item/fileChange/requestApproval");
    if (!command_request and !file_request) {
        self.system("Codex requested an interaction that this agent pane does not support yet.");
        return try protocol.encode(&self.write_buffer, .{ .id = id, .@"error" = .{ .code = -32601, .message = "This Telar client does not support this server request" } });
    }

    if (!protocol.is(protocol.field(params, "threadId"), self.thread()) or
        !protocol.is(protocol.field(params, "turnId"), self.turn_id[0..self.turn_id_len]))
    {
        return try protocol.encode(&self.write_buffer, .{ .id = id, .result = .{ .decision = "decline" } });
    }

    if (self.approval_count == protocol.max_approvals) {
        return error.TooManyApprovalRequests;
    }

    var approval: PendingApproval = .{ .value = .{ .id = self.next_approval, .kind = if (command_request) .command else .file_change } };
    const encoded_id = try protocol.encode(&approval.rpc_id, id);
    approval.rpc_id_len = @intCast(encoded_id.len - 1);
    const description: ApprovalDescription = .{ .params = params, .transcript = &self.transcript, .command_request = command_request };
    description.write(&approval.value) catch |err| return if (err == error.WriteFailed) error.ApprovalDescriptionTooLarge else err;
    self.transcript.update(.{ .role = .system, .text = approval.value.text(), .complete = true });
    self.approvals[self.approval_count] = approval;
    self.approval_count += 1;
    self.next_approval += 1;
    self.transcript.value.status = .blocked;
    self.transcript.value.pending_approval = self.approvals[0].value;
    return null;
}

fn removeApproval(self: *Codex, index: usize) void {
    std.mem.copyForwards(PendingApproval, self.approvals[index .. self.approval_count - 1], self.approvals[index + 1 .. self.approval_count]);
    self.approval_count -= 1;
    self.transcript.value.pending_approval = if (self.approval_count == 0) null else self.approvals[0].value;
    self.transcript.value.status = if (self.approval_count == 0) .working else .blocked;
}

fn copyId(output: []u8, value: []const u8) !void {
    if (value.len == 0 or value.len > output.len or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) {
        return error.InvalidProviderId;
    }

    @memcpy(output[0..value.len], value);
}

const skills_request_id: u64 = 2147483646;
const recent_request_id = 2147483647;

fn finishResume(self: *Codex, result: std.json.Value) !void {
    const thread_value = protocol.field(result, "thread");
    const id = protocol.string(protocol.field(thread_value, "id"));
    if (!std.mem.eql(u8, id, self.resume_target.idSlice()) or !protocol.is(protocol.field(thread_value, "cwd"), self.cwd)) {
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

    const previous = &self.transcript.value;
    const pane_id = previous.pane_id;
    const generation = previous.pane_generation;
    const revision = previous.revision;
    const models = previous.model_storage;
    const model_count = previous.model_count;
    self.transcript = .{ .value = .{ .pane_id = pane_id, .pane_generation = generation, .revision = revision, .options = options, .model_storage = models, .model_count = model_count, .skills = self.skills.value, .resumed = true, .truncated = true, .recent = .{ .phase = .ready } } };
    try copyId(&self.thread_id, id);
    self.thread_id_len = @intCast(id.len);
    @memcpy(self.transcript.value.thread_id[0..id.len], id);
    self.transcript.value.thread_id_len = @intCast(id.len);
    self.children = .{};
    self.children.setRoot(id);
    const name = protocol.string(protocol.field(thread_value, "name"));
    self.metadata.applyName(.{ .string = if (name.len != 0) name else self.resume_target.titleSlice() });
    self.pending_resume_request = null;
    try self.finishStartup();
}

/// Expires optional listing independently; a timed-out resume fails explicitly.
/// Example: `try codex.expireResume();`
pub fn expireResume(self: *Codex) !void {
    if (self.pending_resume_request != null) {
        return error.ProviderResumeTimeout;
    }
}
