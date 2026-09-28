//! The `telar pane` command family: read a pane's text or send it keys
//! without an attached UI client.

const std = @import("std");
const core = @import("telar-core");
const PaneWatcher = @import("PaneWatcher.zig");
const PaneCatalog = @import("PaneCatalog.zig");
const PaneOptions = @import("arguments/PaneOptions.zig");
const Session = @import("Session.zig");
const control = @import("control.zig");
const agent = @import("agent.zig");
const ExecutionContext = @import("ExecutionContext.zig");
const PaneRef = @import("PaneRef.zig");
const values = @import("arguments/values.zig");
const Snapshot = @import("Snapshot.zig");

/// How long `send-keys --enter` waits between the text and Enter. Codex's
/// `PASTE_ENTER_SUPPRESS_WINDOW` is 120 ms.
const submit_delay_ms = 150;

/// Runs one pane command and returns the process exit code.
///
/// ```zig
/// std.process.exit(try pane.run(process_init, options));
/// ```
pub fn run(init: std.process.Init, options: PaneOptions) !u8 {
    var session = if (options.action == .list or options.action == .get or options.action == .search or options.action == .watch) try Session.attach(init, options.socket) else try Session.open(init, options.socket);
    defer session.close();
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    defer writer.flush() catch {};

    return execute(&session, options, .{ .writer = writer, .environ = init.minimal.environ }) catch |err| {
        std.debug.print("telar pane: {s}\n", .{control.describe(err)});
        return switch (err) {
            error.PaneNotFound, error.PaneExited => agent.exit_not_found,
            else => agent.exit_failure,
        };
    };
}

fn execute(session: *Session, options: PaneOptions, context: ExecutionContext) !u8 {
    if (options.action == .list or options.action == .get) {
        return inspect(session, options, context);
    }

    if (options.action == .watch) {
        var watcher: PaneWatcher = .{ .session = session, .options = options, .context = context };
        try watcher.run();
        return agent.exit_ok;
    }

    const pane: PaneRef = if (options.action == .focus)
        .{
            .pane_id = try control.currentPaneId(context.environ),
            .pane_generation = try control.currentPaneGeneration(context.environ),
        }
    else
        try resolvePane(session, options.target, context.environ);

    switch (options.action) {
        .list, .get, .watch => unreachable,
        .search => {
            const response = try session.exchange(core.encodeSearchPane, core.SearchPane{ .request_id = .none, .pane_id = @enumFromInt(pane.pane_id), .needle = std.mem.span(options.text.?) });
            if (response != .pane_matches or core.raw(response.pane_matches.pane_id) != pane.pane_id) {
                return error.UnexpectedRuntimeResponse;
            }

            const found = response.pane_matches;
            var matches = found.matches();
            if (options.json) {
                try context.writer.print("{{\"pane_id\":{d},\"truncated\":{},\"matches\":[", .{ pane.pane_id, found.truncated });
            }

            var separator: []const u8 = "";
            while (try matches.next()) |match| {
                if (options.json) {
                    try context.writer.writeAll(separator);
                    try std.json.Stringify.value(match, .{}, context.writer);
                    separator = ",";
                } else {
                    try context.writer.print("{d}:{d} length={d}\n", .{ match.y, match.x, match.len });
                }
            }

            if (options.json) {
                try context.writer.writeAll("]}\n");
            }
        },
        .read => {
            const text = try session.readPane(pane, .{ .rows = options.lines, .source = options.source });
            if (options.json) {
                try context.writer.print("{{\"pane_id\":{d},\"truncated\":{},\"exit_code\":", .{ text.pane_id, text.truncated });
                if (text.exit_code) |code| {
                    try context.writer.print("{d}", .{code});
                } else {
                    try context.writer.writeAll("null");
                }

                try context.writer.writeAll(",\"text\":");
                try control.writeJsonString(context.writer, text.text);
                try context.writer.writeAll("}\n");
            } else {
                try context.writer.writeAll(text.text);
                if (text.text.len != 0 and text.text[text.text.len - 1] != '\n') {
                    try context.writer.writeByte('\n');
                }
                if (text.truncated) {
                    std.debug.print("telar pane: older rows were omitted\n", .{});
                }

                if (text.exit_code) |code| {
                    std.debug.print("telar pane: the command exited with {d}\n", .{code});
                }
            }
        },
        .send_keys => {
            try session.sendText(pane, .{
                .mode = .raw,
                .text = std.mem.span(options.text.?),
            });

            if (options.enter) {
                // Enter pressed as a person would, after the text: Codex
                // takes an Enter within 120 ms of a fast burst of typed
                // characters for a newline inside a paste.
                session.sleepMs(submit_delay_ms);
                try session.sendText(pane, .{
                    .mode = .raw_enter,
                    .text = "",
                });
            }
        },
        .focus => {
            const result = try session.focusPane(pane, options.direction.?);
            if (options.json) {
                try context.writer.print("{{\"changed\":{},\"focused_pane_id\":{d},\"reason\":\"{s}\"}}\n", .{
                    result.outcome == .focused,
                    core.raw(result.focused_pane_id),
                    @tagName(result.outcome),
                });
            }
        },
    }

    return agent.exit_ok;
}

/// Panes without an agent are still addressable: the generation comes from
/// the agent snapshot when one exists, and otherwise generation 0 asks the
/// runtime for the pane's current generation.
fn resolvePane(session: *Session, target: values.Target, environ: std.process.Environ) !PaneRef {
    const pane_id: u64 = switch (target) {
        .current => try control.currentPaneId(environ),
        .pane => |pane| pane,
        .name, .worktree => return error.InvalidPaneId,
    };

    var snapshot: Snapshot = .{};
    try session.fetchAgents(&snapshot);
    if (try snapshot.resolve(.{ .pane = pane_id }, environ)) |known| {
        return .{ .pane_id = known.pane_id, .pane_generation = known.pane_generation };
    }

    return .{ .pane_id = pane_id, .pane_generation = 0 };
}

fn inspect(session: *Session, options: PaneOptions, context: ExecutionContext) !u8 {
    var catalog: PaneCatalog = .{
        .session = session,
        .workspace = if (options.workspace) |target| try core.workspace(try target.resolve(context.environ, "TELAR_WORKSPACE_ID")) else null,
        .tab = if (options.tab) |target| try core.tab(try target.resolve(context.environ, "TELAR_TAB_ID")) else null,
    };
    try catalog.load();
    if (options.action == .get) {
        const wanted = switch (options.target) {
            .current => try control.currentPaneId(context.environ),
            .pane => |id| id,
            .name, .worktree => return error.InvalidPaneId,
        };
        for (catalog.entries[0..catalog.count]) |*entry| {
            if (core.raw(entry.pane.pane_id) != wanted) {
                continue;
            }

            try entry.write(context.writer, options.json);
            if (options.json) {
                try context.writer.writeByte('\n');
            }

            return agent.exit_ok;
        }

        return error.PaneNotFound;
    }

    if (options.json) {
        try context.writer.writeByte('[');
    } else {
        try context.writer.writeAll("WORKSPACE\tTAB\tPANE\tGENERATION\tLIFECYCLE\n");
    }

    for (catalog.entries[0..catalog.count], 0..) |*entry, index| {
        if (options.json and index != 0) {
            try context.writer.writeByte(',');
        }

        try entry.write(context.writer, options.json);
    }

    if (options.json) {
        try context.writer.writeAll("]\n");
    }

    return agent.exit_ok;
}
