const WriteJob = @import("WriteJob.zig");
const source_namespace = @import("session_checkpoint.zig");
const checkpoint = @import("../../persistence/checkpoint.zig");
const workspace_mod = @import("../../workspace/root.zig");
const pane_mod = @import("../../pane/root.zig");
const agent_mod = @import("../../agent/root.zig");
const std = @import("std");
/// Binds checkpointing to one application type. `Application` provides
/// `io`, `gpa`, `session`, `model`, `select`, `workspaceRepository()`,
/// `launchPane()`, `queueRestoredInput()` and `restoreAgentTitle()`.
///
/// ```zig
/// const SessionCheckpoint = Checkpointer(Application);
/// ```
pub fn Type(comptime Application: type) type {
    return struct {
        /// Marks the session changed at the current monotonic time.
        ///
        /// ```zig
        /// SessionCheckpoint.noteChange(&application);
        /// ```
        pub fn noteChange(application: *Application) void {
            application.session.noteChange(nowNs(application));
        }

        /// Starts one write when the checkpoint is due. Called from the
        /// maintenance tick.
        ///
        /// ```zig
        /// try SessionCheckpoint.flushIfDue(&application);
        /// ```
        pub fn flushIfDue(application: *Application) !void {
            if (!application.session.due(nowNs(application))) {
                return;
            }
            const path = application.session.path.?;

            const job: WriteJob = prepared: {
                const buffer = try application.gpa.alloc(u8, source_namespace.snapshot_bytes);
                errdefer application.gpa.free(buffer);
                const len = try encode(application, buffer);

                break :prepared .{ .io = application.io, .path = path, .buffer = buffer, .len = len };
            };
            try application.session.startWrite(.{ .allocator = application.gpa, .job = job }, application.select);
        }

        /// Completes the in-flight write and releases its buffer.
        ///
        /// ```zig
        /// SessionCheckpoint.handleWritten(&application, result);
        /// ```
        pub fn handleWritten(application: *Application, result: anyerror!void) void {
            application.session.completeWrite(result);
        }

        /// Writes the current shape synchronously. Used at shutdown, after
        /// client connections stop and before panes are torn down.
        ///
        /// ```zig
        /// SessionCheckpoint.writeNow(&application);
        /// ```
        pub fn writeNow(application: *Application) void {
            const path = application.session.path orelse return;
            if (application.session.pending != null) {
                return;
            }
            const buffer = application.gpa.alloc(u8, source_namespace.snapshot_bytes) catch return;
            defer application.gpa.free(buffer);
            const len = encode(application, buffer) catch return;
            source_namespace.writeFile(.{ .io = application.io, .path = path, .buffer = buffer, .len = len }) catch {
                application.session.failures += 1;
                return;
            };
            application.session.dirty = false;
            application.session.writes += 1;
        }

        /// Rebuilds workspaces, tabs, panes and client layouts from the
        /// checkpoint file, if one exists. A file that fails validation is
        /// moved aside as `<path>.corrupt` and ignored.
        ///
        /// ```zig
        /// SessionCheckpoint.restore(&application);
        /// ```
        pub fn restore(application: *Application) void {
            const path = application.session.path orelse return;
            const io = application.io;
            const bytes = source_namespace.Io.Dir.cwd().readFileAlloc(io, path, application.gpa, .limited(checkpoint.max_file_bytes)) catch |err| switch (err) {
                error.FileNotFound => return,
                else => {
                    application.session.restore_failed = true;
                    return;
                },
            };
            defer application.gpa.free(bytes);

            validate(bytes) catch {
                application.session.restore_failed = true;
                quarantine(io, path);
                return;
            };
            apply(application, bytes) catch {
                application.session.restore_failed = true;
            };
        }

        fn validate(bytes: []const u8) !void {
            var reader = try checkpoint.Reader.init(bytes);
            while (try reader.next()) |_| {}
        }

        fn apply(application: *Application, bytes: []const u8) !void {
            var reader = try checkpoint.Reader.init(bytes);
            var repository = application.workspaceRepository();
            const panes = &application.model.panes;
            var layout_sources_ready = false;
            _ = &layout_sources_ready;

            while (try reader.next()) |record| switch (record) {
                .workspace => |workspace| {
                    _ = repository.restoreWorkspace(.{
                        .id = try source_namespace.schema.id.workspace(workspace.id),
                        .path = workspace.path,
                        .explicit_name = if (workspace.name.len != 0) workspace.name else null,
                        .first_tab_id = try source_namespace.schema.id.tab(workspace.first_tab_id),
                        .first_tab_label = workspace.first_tab_label,
                    }) catch continue;
                    application.session.restored_workspaces +|= 1;
                },
                .tab => |tab| {
                    const workspace_id = try source_namespace.schema.id.workspace(tab.workspace_id);
                    repository.restoreTab(.{
                        .workspace = .{ .workspace = workspace_id },
                        .tab_id = try source_namespace.schema.id.tab(tab.tab_id),
                    }, tab.label) catch continue;
                },
                .pane => |pane| restorePane(application, reader.counters, pane) catch continue,
                .layout => |layout| restoreLayout(application, layout) catch continue,
            };

            panes.advanceCounters(reader.counters.next_pane_id, reader.counters.next_pane_generation);
            application.model.workspaces.next_workspace_id = @max(application.model.workspaces.next_workspace_id, reader.counters.next_workspace_id);
            application.model.workspaces.next_tab_id = @max(application.model.workspaces.next_tab_id, reader.counters.next_tab_id);
            dropEmptyTabs(application);
        }

        /// Retires every restored tab that came back without a pane, through
        /// the same operation the final pane exit uses, so a workspace left
        /// without tabs goes with it. A tab exists for clients only together
        /// with a running pane: the tab snapshot query answers `tab_not_found`
        /// for an empty one, and a client that selects it treats that reply
        /// as fatal. Tabs stay empty when a pane record fails to relaunch,
        /// for example because its working directory is gone.
        fn dropEmptyTabs(application: *Application) void {
            var repository = application.workspaceRepository();
            while (findEmptyTab(repository.reader(), &application.model.panes)) |location| {
                _ = workspace_mod.removeTab(&repository, location) orelse break;
                application.session.dropped_tabs +|= 1;
                application.noteSessionChange();
            }
        }

        fn findEmptyTab(reader: workspace_mod.Reader, panes: *const pane_mod.PaneStore) ?source_namespace.schema.TabLocation {
            var entries: [workspace_mod.max_workspaces]source_namespace.schema.WorkspaceListEntry = undefined;
            var tabs: [workspace_mod.max_tabs_per_workspace]source_namespace.schema.TabDescriptor = undefined;
            for (reader.listEntries(&entries)) |entry| {
                const workspace: source_namespace.schema.WorkspaceLocation = .{ .workspace = entry.workspace };
                const snapshot = reader.descriptors(workspace, &tabs) orelse continue;
                for (snapshot.tabs) |tab| {
                    const location: source_namespace.schema.TabLocation = .{ .workspace = workspace, .tab_id = tab.tab_id };
                    if (!panes.hasAt(location)) {
                        return location;
                    }
                }
            }

            return null;
        }

        fn restorePane(application: *Application, counters: checkpoint.Counters, record: checkpoint.PaneRecord) !void {
            const workspace_id = try source_namespace.schema.id.workspace(record.workspace_id);
            const location: source_namespace.schema.TabLocation = .{
                .workspace = .{ .workspace = workspace_id },
                .tab_id = try source_namespace.schema.id.tab(record.tab_id),
            };
            const reader = application.workspaceReader();
            if (!reader.contains(location)) {
                return error.TabNotFound;
            }
            const workspace_path = reader.workspacePath(location.workspace) orelse return error.WorkspaceNotFound;

            var argument_buffer: [checkpoint.max_launch_bytes + 2 * checkpoint.max_launch_arguments]u8 = undefined;
            var encoder = source_namespace.schema.wire.Encoder.init(&argument_buffer);
            var arguments = checkpoint.ArgumentIterator.init(record.arguments);
            while (arguments.next()) |argument| {
                try encoder.writeSized16(argument);
            }
            const encoded_arguments = encoder.finish();
            const size: source_namespace.schema.TerminalSize = .{
                .cols = if (record.cols == 0) 80 else record.cols,
                .rows = if (record.rows == 0) 24 else record.rows,
            };

            try application.model.panes.reserveRestoredKey(record.pane_id, counters.next_pane_generation);
            const pane = try application.launchPane(.{
                .location = location,
                .size = size,
                .launch = .{
                    .cwd = record.cwd,
                    .argument_count = record.argument_count,
                    .encoded_arguments = encoded_arguments,
                    .environment_mode = .inherit_runtime,
                    .environment_count = 0,
                    .encoded_environment = "",
                },
                .launch_cwd = record.cwd,
                .workspace_path = workspace_path,
            });
            application.session.restored_panes +|= 1;

            if (application.session.resume_agents) {
                var command_buffer: [source_namespace.max_resume_command_bytes]u8 = undefined;
                if (source_namespace.resumeCommand(&command_buffer, @enumFromInt(record.agent_provider), record.agent_session)) |command| {
                    try application.queueRestoredInput(pane, command);
                    application.session.resumed_agents +|= 1;
                    if (restoredTitle(record)) |title| {
                        application.restoreAgentTitle(pane, title);
                    }
                }
            }
        }

        /// The title travels only with a session the runtime actually resumes;
        /// a plain relaunched shell must not wear the old agent's title.
        fn restoredTitle(record: checkpoint.PaneRecord) ?agent_mod.SessionTitle {
            if (record.agent_title.len == 0) {
                return null;
            }

            const source = std.enums.fromInt(source_namespace.schema.AgentTitleSource, record.agent_title_source) orelse return null;
            return agent_mod.SessionTitle.init(record.agent_title, source) catch null;
        }

        fn restoreLayout(application: *Application, record: checkpoint.LayoutRecord) !void {
            const message = try source_namespace.schema.decodeClient(record.payload);
            const update = switch (message) {
                .update_client_layout => |view| view,
                else => return error.InvalidCheckpoint,
            };
            try application.model.client_layouts.replace(.{
                .identity = @enumFromInt(record.identity),
                .layout = update,
                .sources = .{
                    .panes = &application.model.panes,
                    .workspaces = application.workspaceReader(),
                },
            });
        }

        fn quarantine(io: source_namespace.Io, path: []const u8) void {
            var corrupt_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const corrupt_path = std.fmt.bufPrint(&corrupt_buffer, "{s}.corrupt", .{path}) catch return;
            source_namespace.Io.Dir.renameAbsolute(path, corrupt_path, io) catch {};
        }

        /// Encodes the restorable model shape into `buffer`.
        ///
        /// ```zig
        /// const len = try encode(&application, buffer);
        /// ```
        pub fn encode(application: *Application, buffer: []u8) !usize {
            const reader = application.workspaceReader();
            const panes = &application.model.panes;
            var encoder = try checkpoint.Encoder.init(buffer, .{
                .next_workspace_id = application.model.workspaces.next_workspace_id,
                .next_tab_id = application.model.workspaces.next_tab_id,
                .next_pane_id = panes.next_id,
                .next_pane_generation = panes.next_generation,
            });

            var entries: [workspace_mod.max_workspaces]source_namespace.schema.WorkspaceListEntry = undefined;
            var descriptor_storage: [workspace_mod.max_tabs_per_workspace]source_namespace.schema.TabDescriptor = undefined;
            for (reader.listEntries(&entries)) |entry| {
                const location: source_namespace.schema.WorkspaceLocation = .{ .workspace = entry.workspace };
                const snapshot = reader.descriptors(location, &descriptor_storage) orelse continue;
                if (snapshot.tabs.len == 0) {
                    continue;
                }
                try encoder.workspace(.{
                    .id = source_namespace.schema.id.raw(entry.workspace),
                    .path = entry.path,
                    .name = reader.explicitName(location) orelse "",
                    .first_tab_id = source_namespace.schema.id.raw(snapshot.tabs[0].tab_id),
                    .first_tab_label = snapshot.tabs[0].label,
                });
                for (snapshot.tabs[1..]) |tab| {
                    try encoder.tab(.{
                        .workspace_id = source_namespace.schema.id.raw(entry.workspace),
                        .tab_id = source_namespace.schema.id.raw(tab.tab_id),
                        .label = tab.label,
                    });
                }
            }

            for (panes.items) |slot| {
                const pane = slot orelse continue;
                if (!pane.launch_state.discoverable() or pane.close_requested or pane.exit != null) {
                    continue;
                }
                if (!pane.launch_record.restorable()) {
                    continue;
                }
                const reference = application.model.agents.sessionReference(pane.key());
                const projected = application.model.agents.projectedProvider(pane.key());
                const title = if (reference != null) application.model.agents.durableTitle(pane.key()) else null;
                try encoder.pane(.{
                    .pane_id = source_namespace.schema.id.raw(pane.id),
                    .workspace_id = source_namespace.schema.id.raw(pane.location.workspace.workspace),
                    .tab_id = source_namespace.schema.id.raw(pane.location.tab_id),
                    .cwd = pane.cwd.slice(),
                    .cols = pane.size.cols,
                    .rows = pane.size.rows,
                    .arguments = pane.launch_record.slice(),
                    .argument_count = pane.launch_record.count,
                    .agent_provider = if (reference != null) @intFromEnum(projected) else 0,
                    .agent_session = if (reference) |value| value.slice() else "",
                    .agent_title = if (title) |value| value.slice() else "",
                    .agent_title_source = if (title) |value| @intFromEnum(value.source) else 0,
                });
            }

            var layout_buffer: [source_namespace.schema.max_client_layout_wire_bytes]u8 = undefined;
            const store = &application.model.client_layouts;
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

        fn nowNs(application: *Application) u64 {
            return @intCast(source_namespace.Io.Timestamp.now(application.io, .awake).toNanoseconds());
        }
    };
}
