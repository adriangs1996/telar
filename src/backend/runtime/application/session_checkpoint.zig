//! Session checkpoint: write-behind persistence of the runtime model's
//! restorable shape and its restoration at startup.
//!
//! Persistence never runs on the interactive path. Semantic changes mark the
//! checkpoint dirty; the periodic maintenance tick snapshots the model into an
//! owned buffer and hands it to a worker that writes a temp file and renames
//! it into place. Restore runs once, before the listener accepts clients.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const checkpoint = @import("../../persistence/checkpoint.zig");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");
const client_layout_store = @import("client_layout_store.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;

pub const debounce_ns: u64 = 500 * std.time.ns_per_ms;
pub const snapshot_bytes = 1024 * 1024;

pub const State = struct {
    path: ?[]const u8 = null,
    /// Type the agent's resume command into a restored pane's shell.
    resume_agents: bool = true,
    dirty: bool = false,
    in_flight: bool = false,
    last_change_ns: u64 = 0,
    writes: u64 = 0,
    failures: u64 = 0,
    restored_workspaces: u16 = 0,
    restored_panes: u16 = 0,
    resumed_agents: u16 = 0,
    /// Restored tabs dropped because none of their panes came back.
    dropped_tabs: u16 = 0,
    restore_failed: bool = false,

    pub fn enabled(state: *const State) bool {
        return state.path != null;
    }

    /// Records one semantic change; the next due tick persists it.
    ///
    /// ```zig
    /// state.noteChange(now_ns);
    /// ```
    pub fn noteChange(state: *State, now_ns: u64) void {
        if (!state.enabled()) return;
        state.dirty = true;
        state.last_change_ns = now_ns;
    }

    /// Reports whether a write should start now: dirty, settled for the
    /// debounce window and no write in flight.
    ///
    /// ```zig
    /// if (state.due(now_ns)) startWrite();
    /// ```
    pub fn due(state: *const State, now_ns: u64) bool {
        return state.enabled() and state.dirty and !state.in_flight and
            now_ns -| state.last_change_ns >= debounce_ns;
    }

    pub fn beginWrite(state: *State) void {
        std.debug.assert(!state.in_flight);
        state.in_flight = true;
        state.dirty = false;
    }

    /// Completes one write. A failure keeps the checkpoint dirty so the next
    /// tick retries; a change that arrived during the write stays dirty too.
    ///
    /// ```zig
    /// state.completeWrite(result);
    /// ```
    pub fn completeWrite(state: *State, result: anyerror!void) void {
        state.in_flight = false;
        if (result) |_| {
            state.writes += 1;
        } else |_| {
            state.failures += 1;
            state.dirty = true;
        }
    }
};

/// Owned bytes handed to the write worker.
pub const WriteJob = struct {
    io: Io,
    path: []const u8,
    buffer: []u8,
    len: usize,

    pub fn bytes(job: *const WriteJob) []const u8 {
        return job.buffer[0..job.len];
    }
};

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
    const file = try Io.Dir.createFileAbsolute(io, temp_path, .{
        .truncate = true,
        .permissions = File.Permissions.fromMode(0o600),
    });
    file.writeStreamingAll(io, job.bytes()) catch |err| {
        file.close(io);
        Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return err;
    };
    file.sync(io) catch |err| {
        file.close(io);
        Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return err;
    };
    file.close(io);
    Io.Dir.renameAbsolute(temp_path, job.path, io) catch |err| {
        Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return err;
    };
}

/// Binds checkpointing to one application type. `Application` provides
/// `io`, `gpa`, `session`, `model`, `select`, `workspaceRepository()`,
/// `launchPane()`, `queueRestoredInput()` and `restoreAgentTitle()`.
///
/// ```zig
/// const SessionCheckpoint = Checkpointer(Application);
/// ```
pub fn Checkpointer(comptime Application: type) type {
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
            if (!application.session.due(nowNs(application))) return;
            const path = application.session.path.?;

            const buffer = try application.gpa.alloc(u8, snapshot_bytes);
            errdefer application.gpa.free(buffer);
            const len = try encode(application, buffer);
            const job: WriteJob = .{ .io = application.io, .path = path, .buffer = buffer, .len = len };
            application.session.beginWrite();
            application.select.concurrent(.checkpoint_written, writeJob, .{job}) catch |err| {
                application.session.completeWrite(err);
                application.gpa.free(buffer);
                return err;
            };
            application.session_write_buffer = buffer;
        }

        /// Completes the in-flight write and releases its buffer.
        ///
        /// ```zig
        /// SessionCheckpoint.handleWritten(&application, result);
        /// ```
        pub fn handleWritten(application: *Application, result: anyerror!void) void {
            application.session.completeWrite(result);
            if (application.session_write_buffer) |buffer| {
                application.gpa.free(buffer);
                application.session_write_buffer = null;
            }
        }

        /// Writes the current shape synchronously. Used at shutdown, after
        /// client connections stop and before panes are torn down.
        ///
        /// ```zig
        /// SessionCheckpoint.writeNow(&application);
        /// ```
        pub fn writeNow(application: *Application) void {
            const path = application.session.path orelse return;
            if (application.session.in_flight) return;
            const buffer = application.gpa.alloc(u8, snapshot_bytes) catch return;
            defer application.gpa.free(buffer);
            const len = encode(application, buffer) catch return;
            writeFile(.{ .io = application.io, .path = path, .buffer = buffer, .len = len }) catch {
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
            const bytes = Io.Dir.cwd().readFileAlloc(io, path, application.gpa, .limited(checkpoint.max_file_bytes)) catch |err| switch (err) {
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
                        .id = try schema.id.workspace(workspace.id),
                        .path = workspace.path,
                        .explicit_name = if (workspace.name.len != 0) workspace.name else null,
                        .first_tab_id = try schema.id.tab(workspace.first_tab_id),
                        .first_tab_label = workspace.first_tab_label,
                    }) catch continue;
                    application.session.restored_workspaces +|= 1;
                },
                .tab => |tab| {
                    const workspace_id = try schema.id.workspace(tab.workspace_id);
                    repository.restoreTab(
                        .{ .workspace = workspace_id },
                        try schema.id.tab(tab.tab_id),
                        tab.label,
                    ) catch continue;
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

        fn findEmptyTab(reader: workspace_mod.Reader, panes: *const pane_mod.PaneStore) ?schema.TabLocation {
            var entries: [workspace_mod.max_workspaces]schema.WorkspaceListEntry = undefined;
            var tabs: [workspace_mod.max_tabs_per_workspace]schema.TabDescriptor = undefined;
            for (reader.listEntries(&entries)) |entry| {
                const workspace: schema.WorkspaceLocation = .{ .workspace = entry.workspace };
                const snapshot = reader.descriptors(workspace, &tabs) orelse continue;
                for (snapshot.tabs) |tab| {
                    const location: schema.TabLocation = .{ .workspace = workspace, .tab_id = tab.tab_id };
                    if (!panes.hasAt(location)) {
                        return location;
                    }
                }
            }

            return null;
        }

        fn restorePane(application: *Application, counters: checkpoint.Counters, record: checkpoint.PaneRecord) !void {
            const workspace_id = try schema.id.workspace(record.workspace_id);
            const location: schema.TabLocation = .{
                .workspace = .{ .workspace = workspace_id },
                .tab_id = try schema.id.tab(record.tab_id),
            };
            const reader = application.workspaceReader();
            if (!reader.contains(location)) return error.TabNotFound;
            const workspace_path = reader.workspacePath(location.workspace) orelse return error.WorkspaceNotFound;

            var argument_buffer: [checkpoint.max_launch_bytes + 2 * checkpoint.max_launch_arguments]u8 = undefined;
            var encoder = schema.wire.Encoder.init(&argument_buffer);
            var arguments = checkpoint.ArgumentIterator.init(record.arguments);
            while (arguments.next()) |argument| {
                try encoder.writeSized16(argument);
            }
            const encoded_arguments = encoder.finish();
            const size: schema.TerminalSize = .{
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
                var command_buffer: [max_resume_command_bytes]u8 = undefined;
                if (resumeCommand(&command_buffer, @enumFromInt(record.agent_provider), record.agent_session)) |command| {
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

            const source = std.enums.fromInt(schema.AgentTitleSource, record.agent_title_source) orelse return null;
            return agent_mod.SessionTitle.init(record.agent_title, source) catch null;
        }

        fn restoreLayout(application: *Application, record: checkpoint.LayoutRecord) !void {
            const message = try schema.decodeClient(record.payload);
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

        fn quarantine(io: Io, path: []const u8) void {
            var corrupt_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const corrupt_path = std.fmt.bufPrint(&corrupt_buffer, "{s}.corrupt", .{path}) catch return;
            Io.Dir.renameAbsolute(path, corrupt_path, io) catch {};
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

            var entries: [workspace_mod.max_workspaces]schema.WorkspaceListEntry = undefined;
            var descriptor_storage: [workspace_mod.max_tabs_per_workspace]schema.TabDescriptor = undefined;
            for (reader.listEntries(&entries)) |entry| {
                const location: schema.WorkspaceLocation = .{ .workspace = entry.workspace };
                const snapshot = reader.descriptors(location, &descriptor_storage) orelse continue;
                if (snapshot.tabs.len == 0) continue;
                try encoder.workspace(.{
                    .id = schema.id.raw(entry.workspace),
                    .path = entry.path,
                    .name = reader.explicitName(location) orelse "",
                    .first_tab_id = schema.id.raw(snapshot.tabs[0].tab_id),
                    .first_tab_label = snapshot.tabs[0].label,
                });
                for (snapshot.tabs[1..]) |tab| {
                    try encoder.tab(.{
                        .workspace_id = schema.id.raw(entry.workspace),
                        .tab_id = schema.id.raw(tab.tab_id),
                        .label = tab.label,
                    });
                }
            }

            for (panes.items) |slot| {
                const pane = slot orelse continue;
                if (!pane.launch_state.discoverable() or pane.close_requested or pane.exit != null) continue;
                if (!pane.launch_record.restorable()) continue;
                const reference = application.model.agents.sessionReference(pane.key());
                const projected = application.model.agents.projectedProvider(pane.key());
                const title = if (reference != null) application.model.agents.durableTitle(pane.key()) else null;
                try encoder.pane(.{
                    .pane_id = schema.id.raw(pane.id),
                    .workspace_id = schema.id.raw(pane.location.workspace.workspace),
                    .tab_id = schema.id.raw(pane.location.tab_id),
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

            var layout_buffer: [schema.max_client_layout_wire_bytes]u8 = undefined;
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

        fn writeJob(job: WriteJob) anyerror!void {
            return writeFile(job);
        }

        fn nowNs(application: *Application) u64 {
            return @intCast(Io.Timestamp.now(application.io, .awake).toNanoseconds());
        }
    };
}

pub const max_resume_command_bytes = 32 + schema.max_agent_session_reference_bytes;

/// Builds the shell line that resumes a built-in agent's session, typed into
/// the restored pane's shell. Only the built-in capability table
/// (`agent.providers`) can produce a command, and only for a reference shaped
/// like a UUID, so a stored reference can never smuggle options or shell
/// syntax.
///
/// ```zig
/// const line = resumeCommand(&buffer, .claude, session) orelse return;
/// ```
pub fn resumeCommand(buffer: *[max_resume_command_bytes]u8, provider: schema.AgentProvider, session: []const u8) ?[]const u8 {
    if (!isUuid(session)) return null;
    const template = agent_mod.providers.of(provider).resume_prefix orelse return null;
    const len = template.len + session.len + 1;
    if (len > buffer.len) return null;
    @memcpy(buffer[0..template.len], template);
    @memcpy(buffer[template.len .. template.len + session.len], session);
    buffer[len - 1] = '\r';
    return buffer[0..len];
}

fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, index| {
        const dash = index == 8 or index == 13 or index == 18 or index == 23;
        if (dash) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

test "resume commands exist only for built-in providers and UUID references" {
    var buffer: [max_resume_command_bytes]u8 = undefined;
    const session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";

    try std.testing.expectEqualStrings("claude --resume " ++ session ++ "\r", resumeCommand(&buffer, .claude, session).?);
    try std.testing.expectEqualStrings("codex resume " ++ session ++ "\r", resumeCommand(&buffer, .codex, session).?);
    try std.testing.expectEqualStrings("pi --session " ++ session ++ "\r", resumeCommand(&buffer, .pi, session).?);
    try std.testing.expect(resumeCommand(&buffer, @enumFromInt(schema.first_custom_agent_provider), session) == null);
    try std.testing.expect(resumeCommand(&buffer, .claude, "not-a-uuid") == null);
    try std.testing.expect(resumeCommand(&buffer, .claude, "0192aaaa-bbbb-cccc-dddd-eeeeffff000g") == null);
}

test "checkpoint state debounces, coalesces and retries after failure" {
    var state: State = .{ .path = "/tmp/session.ckpt" };
    try std.testing.expect(!state.due(0));

    state.noteChange(1_000);
    try std.testing.expect(!state.due(1_000 + debounce_ns - 1));
    try std.testing.expect(state.due(1_000 + debounce_ns));

    state.beginWrite();
    try std.testing.expect(!state.due(std.math.maxInt(u64)));
    state.noteChange(2_000);
    state.completeWrite({});
    try std.testing.expect(state.dirty);
    try std.testing.expectEqual(@as(u64, 1), state.writes);

    state.beginWrite();
    state.completeWrite(error.DiskFull);
    try std.testing.expect(state.dirty);
    try std.testing.expectEqual(@as(u64, 1), state.failures);
    try std.testing.expect(state.due(2_000 + debounce_ns));

    var disabled: State = .{};
    disabled.noteChange(5);
    try std.testing.expect(!disabled.dirty);
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

    const written = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("second!", written);
    const stat = try Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}
