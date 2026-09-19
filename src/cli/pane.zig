//! The `telar pane` command family: read a pane's text or send it keys
//! without an attached UI client.

const std = @import("std");
const core = @import("telar-core");
const PaneCatalog = @import("PaneCatalog.zig");
const PaneOptions = @import("arguments/PaneOptions.zig");
const SessionType = @import("Session.zig");
const control = @import("control.zig");
const agent = @import("agent.zig");
const ExecutionContextType = @import("ExecutionContext.zig");
const PaneRefType = @import("PaneRef.zig");
const max_pane_text_input_bytes_module = @import("telar-core").max_pane_text_input_bytes;
const raw_module = @import("telar-core").raw;
const values = @import("arguments/values.zig");
const SnapshotType = @import("Snapshot.zig");

/// Runs one pane command and returns the process exit code.
///
/// ```zig
/// std.process.exit(try pane.run(process_init, options));
/// ```
pub fn run(init: std.process.Init, options: PaneOptions) !u8 {
    var session = if (options.action == .list or options.action == .get) try SessionType.attach(init, options.socket) else try SessionType.open(init, options.socket);
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

fn execute(session: *SessionType, options: PaneOptions, context: ExecutionContextType) !u8 {
    if (options.action == .list or options.action == .get) {
        return inspect(session, options, context);
    }

    const pane: PaneRefType = if (options.action == .focus)
        .{
            .pane_id = try control.currentPaneId(context.environ),
            .pane_generation = try control.currentPaneGeneration(context.environ),
        }
    else
        try resolvePane(session, options.target, context.environ);

    switch (options.action) {
        .list, .get => unreachable,
        .read => {
            const text = try session.readPane(pane, .{ .rows = options.lines, .source = options.source });
            if (options.json) {
                try context.writer.print("{{\"pane_id\":{d},\"truncated\":{},\"text\":", .{ text.pane_id, text.truncated });
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
            }
        },
        .send_keys => {
            var storage: [max_pane_text_input_bytes_module + 1]u8 = undefined;
            const text = std.mem.span(options.text.?);
            @memcpy(storage[0..text.len], text);
            var len = text.len;
            if (options.enter) {
                storage[len] = '\r';
                len += 1;
            }

            try session.sendText(pane, .{ .mode = .raw, .text = storage[0..len] });
        },
        .focus => {
            const result = try session.focusPane(pane, options.direction.?);
            if (options.json) {
                try context.writer.print("{{\"changed\":{},\"focused_pane_id\":{d},\"reason\":\"{s}\"}}\n", .{
                    result.outcome == .focused,
                    raw_module(result.focused_pane_id),
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
fn resolvePane(session: *SessionType, target: values.Target, environ: std.process.Environ) !PaneRefType {
    const pane_id: u64 = switch (target) {
        .current => try control.currentPaneId(environ),
        .pane => |pane| pane,
        .name => return error.InvalidPaneId,
    };

    var snapshot: SnapshotType = .{};
    try session.fetchAgents(&snapshot);
    if (try snapshot.resolve(.{ .pane = pane_id }, environ)) |known| {
        return .{ .pane_id = known.pane_id, .pane_generation = known.pane_generation };
    }

    return .{ .pane_id = pane_id, .pane_generation = 0 };
}

fn inspect(session: *SessionType, options: PaneOptions, context: ExecutionContextType) !u8 {
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
            .name => return error.InvalidPaneId,
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
        try context.writer.writeAll("WORKSPACE\tTAB\tPANE\tGENERATION\tKIND\tLIFECYCLE\n");
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
