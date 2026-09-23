const pane_launch = @import("../pane_launch.zig");
const pane_input = @import("../pane_input.zig");
const core = @import("telar-core");
const WriteJob = @import("WriteJob.zig");
const session_checkpoint = @import("session_checkpoint.zig");
const std = @import("std");
const checkpoint = @import("../../persistence/checkpoint.zig");
const ReaderType = @import("../../persistence/Reader.zig");
const commands = @import("../../workspace/commands.zig");
const WorkspaceReader = @import("../../workspace/Reader.zig");
const PaneStoreType = @import("../../pane/PaneStore.zig");
const state_support = @import("../../workspace/state_support.zig");
const CountersType = @import("../../persistence/Counters.zig");
const PaneRecordType = @import("../../persistence/PaneRecord.zig");
const ArgumentIteratorType = @import("../../persistence/ArgumentIterator.zig");
const SessionTitleType = @import("../../agent/SessionTitle.zig");
const ResumeSession = @import("../../agent/ResumeSession.zig");
const SessionReference = @import("../../agent/SessionReference.zig");
const LayoutRecordType = @import("../../persistence/LayoutRecord.zig");
const PersistenceEncoder = @import("../../persistence/Encoder.zig");

/// Binds checkpointing to one model type. `RuntimeModel` provides
/// `io`, `gpa`, `session`, `model`, `select`, `workspaceRepository()`,
/// and `restoreAgentTitle()`.
///
/// ```zig
/// const SessionCheckpoint = Checkpointer(RuntimeModel);
/// ```
pub fn Type(comptime RuntimeModel: type) type {
    return struct {
        /// Marks the session changed at the current monotonic time.
        ///
        /// ```zig
        /// SessionCheckpoint.noteChange(&model);
        /// ```
        pub fn noteChange(model: *RuntimeModel) void {
            model.session.noteChange(nowNs(model));
        }

        /// Starts one write when the checkpoint is due. Called from the
        /// maintenance tick.
        ///
        /// ```zig
        /// try SessionCheckpoint.flushIfDue(&model);
        /// ```
        pub fn flushIfDue(model: *RuntimeModel) !void {
            if (!model.session.due(nowNs(model))) {
                return;
            }
            const path = model.session.path.?;

            const job: WriteJob = prepared: {
                const buffer = try model.gpa.alloc(u8, session_checkpoint.snapshot_bytes);
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
            try model.session.startWrite(.{ .allocator = model.gpa, .job = job }, model.select);
        }

        /// Completes the in-flight write and releases its buffer.
        ///
        /// ```zig
        /// SessionCheckpoint.handleWritten(&model, result);
        /// ```
        pub fn handleWritten(model: *RuntimeModel, result: anyerror!void) void {
            model.session.completeWrite(result);
        }

        /// Writes the current shape synchronously. Used at shutdown after
        /// actors are joined and before the canonical model is destroyed.
        ///
        /// ```zig
        /// SessionCheckpoint.writeNow(&model);
        /// ```
        pub fn writeNow(model: *RuntimeModel) void {
            const path = model.session.path orelse return;
            if (model.session.pending != null) {
                return;
            }
            const buffer = model.gpa.alloc(u8, session_checkpoint.snapshot_bytes) catch return;
            defer model.gpa.free(buffer);
            const len = encode(model, buffer) catch return;
            session_checkpoint.writeFile(.{ .io = model.io, .path = path, .buffer = buffer, .len = len }) catch {
                model.session.failures += 1;
                return;
            };
            model.session.dirty = false;
            model.session.writes += 1;
        }

        /// Rebuilds workspaces, tabs, panes and client layouts from the
        /// checkpoint file, if one exists. A file that fails validation is
        /// moved aside as `<path>.corrupt` and ignored.
        ///
        /// ```zig
        /// SessionCheckpoint.restore(&model);
        /// ```
        pub fn restore(model: *RuntimeModel) void {
            const path = model.session.path orelse return;
            const io = model.io;
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, model.gpa, .limited(checkpoint.max_file_bytes)) catch |err| switch (err) {
                error.FileNotFound => return,
                else => {
                    model.session.restore_failed = true;
                    return;
                },
            };
            defer model.gpa.free(bytes);

            validate(bytes) catch {
                model.session.restore_failed = true;
                quarantine(io, path);
                return;
            };
            apply(model, bytes) catch {
                model.session.restore_failed = true;
            };
        }

        fn validate(bytes: []const u8) !void {
            var reader = try ReaderType.init(bytes);
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
            var reader = try ReaderType.init(bytes);
            var repository = model.workspaceRepository();
            const panes = &model.panes;
            var pane_records: [core.max_panes_per_tab]PaneRecordType = undefined;
            var pane_count: usize = 0;

            while (try reader.next()) |record| switch (record) {
                .workspace => |workspace| {
                    _ = repository.restoreWorkspace(.{
                        .id = try core.workspace(workspace.id),
                        .path = workspace.path,
                        .explicit_name = if (workspace.name.len != 0) workspace.name else null,
                        .first_tab_id = try core.tab(workspace.first_tab_id),
                        .first_tab_label = workspace.first_tab_label,
                    }) catch continue;
                    model.session.restored_workspaces +|= 1;
                },
                .tab => |tab| {
                    const workspace_id = try core.workspace(tab.workspace_id);
                    repository.restoreTab(.{
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
            std.mem.sort(PaneRecordType, pane_records[0..pane_count], {}, paneIdLessThan);
            for (pane_records[0..pane_count]) |pane| {
                restorePane(model, reader.counters, pane) catch continue;
            }

            panes.advanceCounters(reader.counters.next_pane_id, reader.counters.next_pane_generation);
            model.workspaces.next_workspace_id = @max(model.workspaces.next_workspace_id, reader.counters.next_workspace_id);
            model.workspaces.next_tab_id = @max(model.workspaces.next_tab_id, reader.counters.next_tab_id);
            dropEmptyTabs(model);

            reader = try ReaderType.init(bytes);
            while (try reader.next()) |record| {
                if (record == .layout) {
                    restoreLayout(model, record.layout) catch continue;
                }
            }
        }

        fn paneIdLessThan(_: void, left: PaneRecordType, right: PaneRecordType) bool {
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
            var repository = model.workspaceRepository();
            while (findEmptyTab(repository.reader(), &model.panes)) |location| {
                _ = commands.removeTab(&repository, location) orelse break;
                model.session.dropped_tabs +|= 1;
                model.noteSessionChange();
            }
        }

        fn findEmptyTab(reader: WorkspaceReader, panes: *const PaneStoreType) ?core.TabLocation {
            var entries: [state_support.max_workspaces]core.WorkspaceListEntry = undefined;
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

        fn restorePane(model: *RuntimeModel, counters: CountersType, record: PaneRecordType) !void {
            const workspace_id = try core.workspace(record.workspace_id);
            const location: core.TabLocation = .{
                .workspace = .{ .workspace = workspace_id },
                .tab_id = try core.tab(record.tab_id),
            };
            const reader = model.workspaceReader();
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
            var arguments = ArgumentIteratorType.init(record.arguments);
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
                try session_checkpoint.directResumeArguments(&direct_encoder, executable, session)
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
            model.session.restored_panes +|= 1;

            if (resumable) |session| {
                if (direct_count == null) {
                    var command_buffer: [session_checkpoint.max_resume_command_bytes]u8 = undefined;
                    const command = session_checkpoint.resumeCommand(&command_buffer, session.provider, session.reference.slice()).?;
                    try pane_input.sendRestored(model, pane, command);
                }

                if (!model.agents.restoreSession(pane.key(), session)) {
                    return error.AgentCapacityExceeded;
                }

                model.session.resumed_agents +|= 1;
                if (restoredTitle(record)) |title| {
                    model.restoreAgentTitle(pane, title);
                }
            }
        }

        fn restoreAgentPane(model: *RuntimeModel, counters: CountersType, record: PaneRecordType) !void {
            const conversation = if (model.session.resume_agents and record.agent_session.len != 0)
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
            const workspace_path = model.workspaceReader().workspacePath(location.workspace) orelse return error.WorkspaceNotFound;
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
            model.session.restored_panes +|= 1;
            if (conversation != null) {
                model.session.resumed_agents +|= 1;
                if (restoredTitle(record)) |title| {
                    model.restoreAgentTitle(pane, title);
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

        fn resumeForPane(model: *RuntimeModel, record: PaneRecordType) ?ResumeSession {
            if (!model.session.resume_agents) {
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
        fn restoredTitle(record: PaneRecordType) ?SessionTitleType {
            if (record.agent_title.len == 0) {
                return null;
            }

            const source = std.enums.fromInt(core.AgentTitleSource, record.agent_title_source) orelse return null;
            return SessionTitleType.init(record.agent_title, source) catch null;
        }

        fn restoreLayout(model: *RuntimeModel, record: LayoutRecordType) !void {
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
                    .workspaces = model.workspaceReader(),
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
        /// const len = try encode(&model, buffer);
        /// ```
        pub fn encode(model: *RuntimeModel, buffer: []u8) !usize {
            const reader = model.workspaceReader();
            const panes = &model.panes;
            var encoder = try PersistenceEncoder.init(buffer, .{
                .next_workspace_id = model.workspaces.next_workspace_id,
                .next_tab_id = model.workspaces.next_tab_id,
                .next_pane_id = panes.next_id,
                .next_pane_generation = panes.next_generation,
            });

            var entries: [state_support.max_workspaces]core.WorkspaceListEntry = undefined;
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

                    break :title if (value.title_len != 0) SessionTitleType.init(value.titleSlice(), .agent) catch null else null;
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
    };
}

test "checkpoint pane records fit the bounded restore storage before model" {
    const Checkpointer = Type(void);
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
            try Checkpointer.validate(bytes);
        } else {
            try std.testing.expectError(error.InvalidCheckpoint, Checkpointer.validate(bytes));
        }
    }
}
