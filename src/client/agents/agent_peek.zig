//! A peek shows one agent without leaving the current tab: its task, plan,
//! last event or answer and the last rows of its pane, read from the runtime
//! when it opens and again with every agent snapshot while it stays open.
//! Its field sends a message to the agent; a few slash words act instead.
//! See `docs/flows/agent-peek.md`.

const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const Client = @import("../execution/Client.zig");
const agent_navigation = @import("agent_navigation.zig");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");
const name_prompt = @import("../input/name_prompt.zig");
const fleet_order = @import("fleet_order.zig");

/// What the field's text does when submitted.
pub const Command = enum {
    /// Empty text: open the agent's tab.
    open,
    /// `/stop`: interrupt the agent's turn.
    stop,
    /// `/diff`: open a tab with the task's diff against its base.
    diff,
    /// Anything else: send the text to the agent as a prompt.
    message,

    /// Example: `const command = Command.of("/stop");`.
    pub fn of(text: []const u8) Command {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "/open")) {
            return .open;
        }

        if (std.mem.eql(u8, trimmed, "/stop")) {
            return .stop;
        }

        if (std.mem.eql(u8, trimmed, "/diff")) {
            return .diff;
        }

        return .message;
    }
};

/// Opens a peek at `key` and asks for its pane's last rows.
///
/// ```zig
/// _ = try agent_peek.open(client, key);
/// ```
pub fn open(client: *Client, key: data.AgentKey) !bool {
    if (!name_prompt.openNamePrompt(&client.model, .{ .peek = key })) {
        return false;
    }

    client.model.peek_screen.show(key);
    try requestScreen(&client.model);
    return true;
}

/// Asks the runtime for the peeked pane's last rows unless a read is on its
/// way or no peek is open.
///
/// ```zig
/// try agent_peek.requestScreen(&client.model);
/// ```
pub fn requestScreen(model: *data.ClientModel) !void {
    const key = peeked(model) orelse return;
    if (model.peek_screen.reading) {
        return;
    }

    try sendEncoded(model, .{ .peek_screen = key.pane_id }, core.encodeReadPane, core.ReadPane{
        .request_id = .none,
        .pane_id = key.pane_id,
        .pane_generation = key.pane_generation,
        .rows = data.PeekScreen.rows,
        .source = .recent,
    });
    model.peek_screen.reading = true;
}

/// Stores a read the peek asked for.
///
/// ```zig
/// try agent_peek.receiveScreen(&client.model, text);
/// ```
pub fn receiveScreen(model: *data.ClientModel, text: core.PaneText) !void {
    const continuation = model.request_lifecycle.tracker.take(text.request_id) orelse return error.UnexpectedControlReply;
    if (continuation != .peek_screen) {
        return error.UnexpectedControlReply;
    }

    _ = model.peek_screen.store(text.pane_id, text.text);
}

/// Drops the peek's pane text once its prompt is gone.
///
/// ```zig
/// agent_peek.settle(&client.model);
/// ```
pub fn settle(model: *data.ClientModel) void {
    if (model.peek_screen.agent != null and peeked(model) == null) {
        model.peek_screen.close();
    }
}

/// Acts on the peek field's text; returns whether the peek closes.
///
/// ```zig
/// const close = try agent_peek.submit(client, key, "/stop");
/// ```
pub fn submit(client: *Client, key: data.AgentKey, text: []const u8) !bool {
    const model = &client.model;
    switch (Command.of(text)) {
        .open => _ = try agent_navigation.navigateAgent(client, key),
        .stop => try sendEncoded(model, .{ .peek_action = key.pane_id }, core.encodeInterruptAgent, core.InterruptAgent{
            .request_id = .none,
            .pane_id = key.pane_id,
            .pane_generation = key.pane_generation,
        }),
        .diff => try openDiff(model, key),
        .message => try sendEncoded(model, .{ .peek_action = key.pane_id }, core.encodeSendPaneText, core.SendPaneText{
            .request_id = .none,
            .pane_id = key.pane_id,
            .pane_generation = key.pane_generation,
            .mode = .prompt,
            .text = std.mem.trim(u8, text, " \t"),
        }),
    }

    model.peek_screen.close();
    return true;
}

/// Takes the user to the diff tab a peek opened, in the worktree's own
/// workspace. A handoff waits for no other request; with one in flight the
/// tab stays where the task card reaches it.
///
/// ```zig
/// try agent_peek.showOpened(client, opened);
/// ```
pub fn showOpened(client: *Client, opened: core.PaneOpened) !void {
    const workspace = switch (opened.location.workspace) {
        .workspace => |id| id,
        .worktree => return,
    };

    if (!client.model.request_lifecycle.tracker.isEmpty()) {
        return;
    }

    _ = try workspace_handoff.requestWorkspacePane(client, opened.pane_id, workspace);
}

/// Opens a tab in the task's worktree showing its diff against its base,
/// then leaves a shell there.
fn openDiff(model: *data.ClientModel, key: data.AgentKey) !void {
    const agent = model.agent_snapshot.find(key) orelse return;
    const row = fleet_order.taskRow(&model.workspace_list_snapshot, agent) orelse return;
    const base = if (row.baseSlice().len != 0) row.baseSlice() else "HEAD";
    const arguments = [_][]const u8{ "sh", "-c", diff_script, "sh", base };
    try sendEncoded(model, .{ .peek_action = key.pane_id }, core.encodeLaunchWorktree, core.LaunchWorktree{
        .request_id = .none,
        .worktree = row.worktree,
        .label = "diff",
        .size = diff_size,
        .launch = .{
            .cwd = if (row.pathSlice().len != 0) row.pathSlice() else "/",
            .arguments = &arguments,
        },
    });
}

/// Diff against the merge base with the task's base branch, then a shell.
const diff_script = "mb=$(git merge-base \"$1\" HEAD 2>/dev/null || echo HEAD); git --no-pager diff --stat \"$mb\"; echo; git diff \"$mb\"; exec \"${SHELL:-/bin/sh}\"";
const diff_size: core.TerminalSize = .{ .cols = 160, .rows = 48 };

fn peeked(model: *const data.ClientModel) ?data.AgentKey {
    const prompt = model.name_prompt.currentConst() orelse return null;
    return switch (prompt.target()) {
        .peek => |key| key,
        else => null,
    };
}

fn sendEncoded(model: *data.ClientModel, continuation: data.RequestsContinuation, comptime encode: anytype, value: anytype) !void {
    const request_id = try model.request_lifecycle.nextId();
    try model.request_lifecycle.tracker.add(request_id, continuation);
    errdefer _ = model.request_lifecycle.tracker.take(request_id);
    var request = value;
    request.request_id = request_id;
    try model.to_runtime.pushEncoded(encode, request);
}

test "the field's text selects what the peek does" {
    try std.testing.expectEqual(Command.open, Command.of(""));
    try std.testing.expectEqual(Command.open, Command.of("  /open "));
    try std.testing.expectEqual(Command.stop, Command.of("/stop"));
    try std.testing.expectEqual(Command.diff, Command.of("/diff"));
    try std.testing.expectEqual(Command.message, Command.of("please add tests"));
}
