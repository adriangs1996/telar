//! Session checkpoint: write-behind persistence of the runtime model's
//! restorable shape and its restoration at startup.
//!
//! Persistence never runs on the interactive path. Semantic changes mark the
//! checkpoint dirty; the maintenance tick snapshots the model into an owned
//! buffer and hands it to a worker that writes a temp file and renames it
//! into place. Restore runs once, before the listener accepts clients.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const CheckpointWriter = @import("CheckpointWriter.zig");
const WriteJob = @import("application/WriteJob.zig");
const TestingScheduler = @import("application/TestingScheduler.zig");
const OwnedWrite = @import("application/OwnedWrite.zig");
const Pane = @import("../pane/Pane.zig");
const PaneStore = @import("../pane/PaneStore.zig");
const checkpoint = @import("../persistence/checkpoint.zig");
const PersistenceReader = @import("../persistence/Reader.zig");
const Counters = @import("../persistence/Counters.zig");
const PaneRecord = @import("../persistence/PaneRecord.zig");
const ArgumentIterator = @import("../persistence/ArgumentIterator.zig");
const LayoutRecord = @import("../persistence/LayoutRecord.zig");
const PersistenceEncoder = @import("../persistence/Encoder.zig");
const Workspaces = @import("../workspace/Workspaces.zig");
const SessionTitle = @import("../agent/SessionTitle.zig");
const ResumeSession = @import("../agent/ResumeSession.zig");
const SessionReference = @import("../agent/SessionReference.zig");
const providers = @import("../agent/providers/providers.zig");
const pane_input = @import("pane_input.zig");
const pane_launch = @import("pane_launch.zig");

pub const debounce_ns: u64 = 500 * std.time.ns_per_ms;
pub const snapshot_bytes = 1024 * 1024;

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
    const file = try std.Io.Dir.createFileAbsolute(io, temp_path, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    file.writeStreamingAll(io, job.bytes()) catch |err| {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return err;
    };
    file.sync(io) catch |err| {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return err;
    };
    file.close(io);
    std.Io.Dir.renameAbsolute(temp_path, job.path, io) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return err;
    };
}

pub const max_resume_command_bytes = 32 + core.max_agent_session_reference_bytes;

/// Builds the shell line that resumes a built-in agent's session, typed into
/// the restored pane's shell. Only the built-in capability table
/// (`agent.providers`) can produce a command, and only for a reference shaped
/// like a UUID, so a stored reference can never smuggle options or shell
/// syntax.
///
/// ```zig
/// const line = resumeCommand(&buffer, .claude, session) orelse return;
/// ```
pub fn resumeCommand(buffer: *[max_resume_command_bytes]u8, provider: core.AgentProvider, session: []const u8) ?[]const u8 {
    const reference = SessionReference.init(session, 0) catch return null;
    _ = ResumeSession.init(provider, reference) catch return null;
    const template = providers.of(provider).resume_prefix orelse return null;
    const len = template.len + session.len + 1;
    if (len > buffer.len) {
        return null;
    }
    @memcpy(buffer[0..template.len], template);
    @memcpy(buffer[template.len .. template.len + session.len], session);
    buffer[len - 1] = '\r';
    return buffer[0..len];
}

/// Rebuilds fixed resume argv only when the original executable is the same
/// built-in agent. Shells keep their argv and receive the shell resume line.
/// Example: `const count = try directResumeArguments(&encoder, executable, session);`.
pub fn directResumeArguments(encoder: *core.Encoder, executable: []const u8, session: ResumeSession) !?u16 {
    const prefix = providers.of(session.provider).resume_prefix orelse return null;
    var words = std.mem.tokenizeScalar(u8, prefix, ' ');
    const command = words.next() orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(executable), command)) {
        return null;
    }

    try encoder.writeSized16(executable);
    var count: u16 = 1;
    while (words.next()) |word| {
        try encoder.writeSized16(word);
        count += 1;
    }

    try encoder.writeSized16(session.reference.slice());
    return count + 1;
}

/// Marks the session changed at the current monotonic time.
///
/// ```zig
/// session_checkpoint.noteChange(model);
/// ```
pub fn noteChange(model: *RuntimeModel) void {
    model.checkpoint.noteChange(nowNs(model));
}

/// Starts one write when the checkpoint is due. Called from the
/// maintenance tick.
///
/// ```zig
/// try session_checkpoint.start(model);
/// ```
pub fn start(model: *RuntimeModel) !void {
    if (!model.checkpoint.due(nowNs(model))) {
        return;
    }
    const path = model.checkpoint.path.?;

    const job: WriteJob = prepared: {
        const buffer = try model.gpa.alloc(u8, snapshot_bytes);
        errdefer model.gpa.free(buffer);
        const len = encode(model, buffer) catch |err| switch (err) {
            error.AgentBusy => {
                model.gpa.free(buffer);
                return;
            },
            else => return err,
        };

        break :prepared .{ .io = model.io, .path = path, .buffer = buffer, .len = len };
    };
    try model.checkpoint.startWrite(.{ .allocator = model.gpa, .job = job }, model.select);
}

/// Completes the in-flight write and releases its buffer.
///
/// ```zig
/// session_checkpoint.finish(model, result);
/// ```
pub fn finish(model: *RuntimeModel, result: anyerror!void) void {
    model.checkpoint.completeWrite(result);
}

/// Writes the current shape synchronously. Used at shutdown after
/// actors are joined and before the canonical model is destroyed.
///
/// ```zig
/// session_checkpoint.writeNow(model);
/// ```
pub fn writeNow(model: *RuntimeModel) void {
    const path = model.checkpoint.path orelse return;
    if (model.checkpoint.pending != null) {
        return;
    }
    const buffer = model.gpa.alloc(u8, snapshot_bytes) catch return;
    defer model.gpa.free(buffer);
    const len = encode(model, buffer) catch return;
    writeFile(.{ .io = model.io, .path = path, .buffer = buffer, .len = len }) catch {
        model.checkpoint.failures += 1;
        return;
    };
    model.checkpoint.dirty = false;
    model.checkpoint.writes += 1;
}

/// Rebuilds workspaces, tabs, panes and client layouts from the
/// checkpoint file, if one exists. A file that fails validation is
/// moved aside as `<path>.corrupt` and ignored.
///
/// ```zig
/// session_checkpoint.restore(model);
/// ```
pub fn restore(model: *RuntimeModel) void {
    const path = model.checkpoint.path orelse return;
    const io = model.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, model.gpa, .limited(checkpoint.max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            model.checkpoint.restore_failed = true;
            return;
        },
    };
    defer model.gpa.free(bytes);

    validate(bytes) catch {
        model.checkpoint.restore_failed = true;
        quarantine(io, path);
        return;
    };
    apply(model, bytes) catch {
        model.checkpoint.restore_failed = true;
    };
}

fn validate(bytes: []const u8) !void {
    var reader = try PersistenceReader.init(bytes);
    var pane_count: usize = 0;
    while (try reader.next()) |record| {
        if (record == .pane) {
            pane_count += 1;
            if (pane_count > core.max_panes_per_tab) {
                return error.InvalidCheckpoint;
            }
        }
    }
}

fn apply(model: *RuntimeModel, bytes: []const u8) !void {
    var reader = try PersistenceReader.init(bytes);
    const panes = &model.panes;
    var pane_records: [core.max_panes_per_tab]PaneRecord = undefined;
    var pane_count: usize = 0;

    while (try reader.next()) |record| switch (record) {
        .workspace => |workspace| {
            _ = model.workspaces.restore(model.gpa, .{
                .id = try core.workspace(workspace.id),
                .path = workspace.path,
                .explicit_name = if (workspace.name.len != 0) workspace.name else null,
                .first_tab_id = try core.tab(workspace.first_tab_id),
                .first_tab_label = workspace.first_tab_label,
            }) catch continue;
            model.checkpoint.restored_workspaces +|= 1;
        },
        .tab => |tab| {
            const workspace_id = try core.workspace(tab.workspace_id);
            model.workspaces.restoreTab(.{
                .workspace = .{ .workspace = workspace_id },
                .tab_id = try core.tab(tab.tab_id),
            }, tab.label) catch continue;
        },
        .pane => |pane| {
            pane_records[pane_count] = pane;
            pane_count += 1;
        },
        .layout => {},
    };

    // Reused slots serialize newer identities before older live panes.
    // Restored key reservation must still advance monotonically.
    std.mem.sort(PaneRecord, pane_records[0..pane_count], {}, paneIdLessThan);
    for (pane_records[0..pane_count]) |pane| {
        restorePane(model, reader.counters, pane) catch continue;
    }

    panes.advanceCounters(reader.counters.next_pane_id, reader.counters.next_pane_generation);
    model.workspaces.next_workspace_id = @max(model.workspaces.next_workspace_id, reader.counters.next_workspace_id);
    model.workspaces.next_tab_id = @max(model.workspaces.next_tab_id, reader.counters.next_tab_id);
    dropEmptyTabs(model);

    reader = try PersistenceReader.init(bytes);
    while (try reader.next()) |record| {
        if (record == .layout) {
            restoreLayout(model, record.layout) catch continue;
        }
    }
}

fn paneIdLessThan(_: void, left: PaneRecord, right: PaneRecord) bool {
    return left.pane_id < right.pane_id;
}

/// Retires every restored tab that came back without a pane, through
/// the same operation the final pane exit uses, so a workspace left
/// without tabs goes with it. A tab exists for clients only together
/// with a running pane: the tab snapshot query answers `tab_not_found`
/// for an empty one, and a client that selects it treats that reply
/// as fatal. Tabs stay empty when a pane record fails to relaunch,
/// for example because its working directory is gone.
fn dropEmptyTabs(model: *RuntimeModel) void {
    while (findEmptyTab(&model.workspaces, &model.panes)) |location| {
        _ = model.workspaces.removeTab(model.gpa, location) orelse break;
        model.checkpoint.dropped_tabs +|= 1;
        noteChange(model);
    }
}

fn findEmptyTab(reader: *const Workspaces, panes: *const PaneStore) ?core.TabLocation {
    var entries: [Workspaces.capacity]core.WorkspaceListEntry = undefined;
    var tabs: [core.max_tabs_per_workspace]core.TabDescriptor = undefined;
    for (reader.listEntries(&entries)) |entry| {
        const workspace: core.WorkspaceLocation = .{ .workspace = entry.workspace };
        const snapshot = reader.descriptors(workspace, &tabs) orelse continue;
        for (snapshot.tabs) |tab| {
            const location: core.TabLocation = .{ .workspace = workspace, .tab_id = tab.tab_id };
            if (!panes.hasAt(location)) {
                return location;
            }
        }
    }

    return null;
}

fn restorePane(model: *RuntimeModel, counters: Counters, record: PaneRecord) !void {
    const workspace_id = try core.workspace(record.workspace_id);
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = workspace_id },
        .tab_id = try core.tab(record.tab_id),
    };
    const reader = &model.workspaces;
    if (!reader.contains(location)) {
        return error.TabNotFound;
    }
    const workspace_path = reader.workspacePath(location.workspace) orelse return error.WorkspaceNotFound;

    if (record.kind == .agent) {
        return restoreAgentPane(model, counters, record);
    }

    var argument_buffer: [checkpoint.max_launch_bytes + 2 * checkpoint.max_launch_arguments]u8 = undefined;
    var encoder = core.Encoder.init(&argument_buffer);
    const resumable = resumeForPane(model, record);
    var arguments = ArgumentIterator.init(record.arguments);
    const executable = arguments.next() orelse return error.InvalidLaunch;
    try encoder.writeSized16(executable);
    while (arguments.next()) |argument| {
        try encoder.writeSized16(argument);
    }

    const original_launch: core.LaunchView = .{
        .cwd = record.cwd,
        .argument_count = record.argument_count,
        .encoded_arguments = encoder.finish(),
        .environment_mode = .inherit_runtime,
        .environment_count = 0,
        .encoded_environment = "",
    };
    var direct_buffer: [checkpoint.max_launch_bytes + 2 * checkpoint.max_launch_arguments]u8 = undefined;
    var direct_encoder = core.Encoder.init(&direct_buffer);
    const direct_count = if (resumable) |session|
        try directResumeArguments(&direct_encoder, executable, session)
    else
        null;
    const size: core.TerminalSize = .{
        .cols = if (record.cols == 0) 80 else record.cols,
        .rows = if (record.rows == 0) 24 else record.rows,
    };

    try model.panes.reserveRestoredKey(record.pane_id, counters.next_pane_generation);
    const pane = try pane_launch.launch(model, .{
        .location = location,
        .size = size,
        .launch = .{
            .cwd = record.cwd,
            .argument_count = direct_count orelse record.argument_count,
            .encoded_arguments = if (direct_count != null) direct_encoder.finish() else original_launch.encoded_arguments,
            .environment_mode = .inherit_runtime,
            .environment_count = 0,
            .encoded_environment = "",
        },
        .launch_cwd = record.cwd,
        .workspace_path = workspace_path,
    });
    pane.launch_record.capture(original_launch);
    model.checkpoint.restored_panes +|= 1;

    if (resumable) |session| {
        if (direct_count == null) {
            var command_buffer: [max_resume_command_bytes]u8 = undefined;
            const command = resumeCommand(&command_buffer, session.provider, session.reference.slice()).?;
            try pane_input.sendRestored(model, pane, command);
        }

        if (!model.agents.restoreSession(pane.key(), session)) {
            return error.AgentCapacityExceeded;
        }

        model.checkpoint.resumed_agents +|= 1;
        if (restoredTitle(record)) |title| {
            restoreAgentTitle(model, pane, title);
        }
    }
}

fn restoreAgentPane(model: *RuntimeModel, counters: Counters, record: PaneRecord) !void {
    const conversation = if (model.checkpoint.resume_agents and record.agent_session.len != 0)
        try core.RecentConversation.init(record.agent_session, record.agent_title)
    else
        null;
    if (conversation) |value| {
        if (managedConversationClaimed(model, value.idSlice())) {
            return error.ConversationAlreadyOpen;
        }

        const reference = try SessionReference.init(value.idSlice(), 0);
        if (ResumeSession.init(.codex, reference)) |session| {
            if (model.agents.hasRestoredSession(session)) {
                return error.ConversationAlreadyOpen;
            }
        } else |_| {}
    }

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = try core.workspace(record.workspace_id) },
        .tab_id = try core.tab(record.tab_id),
    };
    const workspace_path = model.workspaces.workspacePath(location.workspace) orelse return error.WorkspaceNotFound;
    try model.panes.reserveRestoredKey(record.pane_id, counters.next_pane_generation);
    const pane = try pane_launch.launch(model, .{
        .location = location,
        .kind = .agent,
        .restore_conversation = conversation,
        .size = .{ .cols = if (record.cols == 0) 80 else record.cols, .rows = if (record.rows == 0) 24 else record.rows },
        .launch = .{ .cwd = record.cwd, .argument_count = 0, .encoded_arguments = "", .environment_mode = .inherit_runtime, .environment_count = 0, .encoded_environment = "" },
        .launch_cwd = record.cwd,
        .workspace_path = workspace_path,
    });
    model.checkpoint.restored_panes +|= 1;
    if (conversation != null) {
        model.checkpoint.resumed_agents +|= 1;
        if (restoredTitle(record)) |title| {
            restoreAgentTitle(model, pane, title);
        }
    }
}

fn managedConversationClaimed(model: *RuntimeModel, id: []const u8) bool {
    for (model.panes.items) |slot| {
        const pane = slot orelse continue;
        if (pane.agent_thread) |snapshot| {
            if (std.mem.eql(u8, snapshot.threadId(), id)) {
                return true;
            }
        }
    }

    return false;
}

fn resumeForPane(model: *RuntimeModel, record: PaneRecord) ?ResumeSession {
    if (!model.checkpoint.resume_agents) {
        return null;
    }

    const reference = SessionReference.init(record.agent_session, 0) catch return null;
    const session = ResumeSession.init(@enumFromInt(record.agent_provider), reference) catch return null;
    if (model.agents.hasRestoredSession(session) or (session.provider == .codex and managedConversationClaimed(model, record.agent_session))) {
        return null;
    }

    return session;
}

/// The title travels only with a session the runtime actually resumes;
/// a plain relaunched shell must not wear the old agent's title.
fn restoredTitle(record: PaneRecord) ?SessionTitle {
    if (record.agent_title.len == 0) {
        return null;
    }

    const source = std.enums.fromInt(core.AgentTitleSource, record.agent_title_source) orelse return null;
    return SessionTitle.init(record.agent_title, source) catch null;
}

fn restoreLayout(model: *RuntimeModel, record: LayoutRecord) !void {
    const message = try core.decodeClient(record.payload);
    const update = switch (message) {
        .update_client_layout => |view| view,
        else => return error.InvalidCheckpoint,
    };
    try model.client_layouts.replace(.{
        .identity = @enumFromInt(record.identity),
        .layout = update,
        .sources = .{
            .panes = &model.panes,
            .workspaces = &model.workspaces,
        },
    });
}

fn quarantine(io: std.Io, path: []const u8) void {
    var corrupt_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const corrupt_path = std.fmt.bufPrint(&corrupt_buffer, "{s}.corrupt", .{path}) catch return;
    std.Io.Dir.renameAbsolute(path, corrupt_path, io) catch {};
}

/// Encodes the restorable model shape into `buffer`.
///
/// ```zig
/// const len = try session_checkpoint.encode(model, buffer);
/// ```
pub fn encode(model: *RuntimeModel, buffer: []u8) !usize {
    const reader = &model.workspaces;
    const panes = &model.panes;
    var encoder = try PersistenceEncoder.init(buffer, .{
        .next_workspace_id = model.workspaces.next_workspace_id,
        .next_tab_id = model.workspaces.next_tab_id,
        .next_pane_id = panes.next_id,
        .next_pane_generation = panes.next_generation,
    });

    var entries: [Workspaces.capacity]core.WorkspaceListEntry = undefined;
    var descriptor_storage: [core.max_tabs_per_workspace]core.TabDescriptor = undefined;
    for (reader.listEntries(&entries)) |entry| {
        const location: core.WorkspaceLocation = .{ .workspace = entry.workspace };
        const snapshot = reader.descriptors(location, &descriptor_storage) orelse continue;
        if (snapshot.tabs.len == 0) {
            continue;
        }
        try encoder.workspace(.{
            .id = core.raw(entry.workspace),
            .path = entry.path,
            .name = reader.explicitName(location) orelse "",
            .first_tab_id = core.raw(snapshot.tabs[0].tab_id),
            .first_tab_label = snapshot.tabs[0].label,
        });
        for (snapshot.tabs[1..]) |tab| {
            try encoder.tab(.{
                .workspace_id = core.raw(entry.workspace),
                .tab_id = core.raw(tab.tab_id),
                .label = tab.label,
            });
        }
    }

    for (panes.items) |slot| {
        const pane = slot orelse continue;
        if (!pane.launch_state.discoverable() or pane.close_requested or pane.exit != null) {
            continue;
        }
        if (pane.kind == .terminal and !pane.launch_record.restorable()) {
            continue;
        }

        const conversation = if (pane.kind == .agent) try pane.session.agent.session.checkpoint(model.io) else null;
        const resumable = if (pane.kind == .terminal) model.agents.resumeSession(pane.key()) else null;
        const title = if (conversation) |*value| title: {
            if (std.mem.eql(u8, pane.agent_thread.?.threadId(), value.idSlice())) {
                if (model.agents.checkpointTitle(pane.key())) |saved| {
                    break :title saved;
                }
            }

            break :title if (value.title_len != 0) SessionTitle.init(value.titleSlice(), .agent) catch null else null;
        } else if (resumable != null) model.agents.checkpointTitle(pane.key()) else null;
        try encoder.pane(.{
            .kind = pane.kind,
            .pane_id = core.raw(pane.id),
            .workspace_id = core.raw(pane.location.workspace.workspace),
            .tab_id = core.raw(pane.location.tab_id),
            .cwd = pane.cwd.slice(),
            .cols = pane.size.cols,
            .rows = pane.size.rows,
            .arguments = if (pane.kind == .agent) "" else pane.launch_record.slice(),
            .argument_count = if (pane.kind == .agent) 0 else pane.launch_record.count,
            .agent_provider = if (pane.kind == .agent) @intFromEnum(core.AgentProvider.codex) else if (resumable) |session| @intFromEnum(session.provider) else 0,
            .agent_session = if (conversation) |*value| value.idSlice() else if (resumable) |session| session.reference.slice() else "",
            .agent_title = if (title) |value| value.slice() else "",
            .agent_title_source = if (title) |value| @intFromEnum(value.source) else 0,
        });
    }

    var layout_buffer: [core.max_client_layout_wire_bytes]u8 = undefined;
    const store = &model.client_layouts;
    var index: usize = 0;
    while (index < store.capacity()) : (index += 1) {
        const exported = try store.exportRecord(index, &layout_buffer) orelse continue;
        try encoder.layout(.{
            .identity = @intFromEnum(exported.identity),
            .last_used = exported.last_used,
            .payload = exported.payload,
        });
    }

    return (try encoder.finish()).len;
}

fn nowNs(model: *RuntimeModel) u64 {
    return @intCast(std.Io.Timestamp.now(model.io, .awake).toNanoseconds());
}

/// Hands a checkpointed title to the agent that will resume in a restored
/// pane and records it for the pane's new history session, so the sidebar
/// and the history palette show the resumed session under its old name.
///
/// ```zig
/// session_checkpoint.restoreAgentTitle(model, pane, title);
/// ```
pub fn restoreAgentTitle(model: *RuntimeModel, pane: *const Pane, title: SessionTitle) void {
    if (!model.agents.restoreTitle(pane.key(), title)) {
        return;
    }

    _ = model.resources.history.service().setSessionTitle(model.io, .{
        .id = pane.history_session_id,
        .title = title.slice(),
        .source = title.source,
        .state = .ready,
    });
}

test "resume commands exist only for built-in providers and UUID references" {
    var buffer: [max_resume_command_bytes]u8 = undefined;
    const session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";

    try std.testing.expectEqualStrings("claude --resume " ++ session ++ "\r", resumeCommand(&buffer, .claude, session).?);
    try std.testing.expectEqualStrings("codex resume " ++ session ++ "\r", resumeCommand(&buffer, .codex, session).?);
    try std.testing.expectEqualStrings("pi --session " ++ session ++ "\r", resumeCommand(&buffer, .pi, session).?);
    try std.testing.expect(resumeCommand(&buffer, @enumFromInt(core.first_custom_agent_provider), session) == null);
    try std.testing.expect(resumeCommand(&buffer, .claude, "not-a-uuid") == null);
    try std.testing.expect(resumeCommand(&buffer, .claude, "0192aaaa-bbbb-cccc-dddd-eeeeffff000g") == null);
}

test "checkpoint state debounces, coalesces and retries after failure" {
    var state: CheckpointWriter = .{ .path = "/tmp/session.ckpt" };
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

    var disabled: CheckpointWriter = .{};
    disabled.noteChange(5);
    try std.testing.expect(!disabled.dirty);
}

fn testingWrite() !OwnedWrite {
    return .{
        .allocator = std.testing.allocator,
        .job = .{ .io = std.testing.io, .path = "/unused", .buffer = try std.testing.allocator.alloc(u8, 1), .len = 1 },
    };
}

test "checkpoint startup failure releases ownership once and permits retry" {
    var state: CheckpointWriter = .{ .path = "/unused", .dirty = true };
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

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("second!", written);
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}

test "checkpoint pane records fit the bounded restore storage before model" {
    var buffer: [16384]u8 = undefined;
    for ([_]usize{ core.max_panes_per_tab, core.max_panes_per_tab + 1 }) |count| {
        var encoder = try PersistenceEncoder.init(&buffer, .{
            .next_workspace_id = 2,
            .next_tab_id = 2,
            .next_pane_id = count + 1,
            .next_pane_generation = count + 1,
        });
        for (0..count) |index| {
            try encoder.pane(.{
                .pane_id = index + 1,
                .workspace_id = 1,
                .tab_id = 1,
                .cwd = "/",
                .cols = 80,
                .rows = 24,
                .arguments = "/bin/sh\x00",
                .argument_count = 1,
            });
        }

        const bytes = try encoder.finish();
        if (count <= core.max_panes_per_tab) {
            try validate(bytes);
        } else {
            try std.testing.expectError(error.InvalidCheckpoint, validate(bytes));
        }
    }
}
