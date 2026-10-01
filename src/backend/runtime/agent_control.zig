//! Automation drives agents in other panes: it interrupts their turn, and
//! every text it sends passes the rules that keep a person in charge. Text
//! never reaches the pane a person has focused, a sending pane is named on
//! the prompt it sends, and prompts between two panes are budgeted. See
//! `docs/flows/agent-control.md`.

const std = @import("std");
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const Pane = @import("../pane/Pane.zig");
const prompt_scan = @import("../history/prompt_scan.zig");
const agent_types = @import("../agent/types.zig");
const agent_status = @import("agent_status.zig");
const client_request = @import("client_request.zig");
const pane_input = @import("pane_input.zig");
const agent_identity = @import("agent_identity.zig");

/// The event line an interrupted agent shows until its next hook.
pub const interrupted_event = "Interrupted by telar";

/// Bound for the line that names a sending pane on its prompt.
pub const max_sender_line_bytes = 192;
/// Bytes of the branch or workspace name the sender line keeps.
const max_sender_name_bytes = 64;

/// Stops a working agent's current turn with the key its manifest declares.
///
/// ```zig
/// try agent_control.interrupt(model, session, request);
/// ```
pub fn interrupt(model: *RuntimeModel, session: *Session, request: core.InterruptAgent) !void {
    const key: PaneKey = .{ .id = request.pane_id, .generation = request.pane_generation };
    const pane = model.panes.resolveControl(key) orelse {
        return client_request.fail(session, request.request_id, .pane_not_found, "pane not found");
    };

    if (pane.exit != null) {
        return client_request.fail(session, request.request_id, .pane_exited, "pane already exited");
    }

    if (focusedByClient(model, pane.id)) {
        return client_request.fail(session, request.request_id, .pane_focused, "the pane has the focus in an attached window");
    }

    const exact = pane.key();
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
    if (model.agents.find(exact)) |agent| {
        // A press right after another could reach an agent whose turn just
        // stopped: Claude Code exits on a second Ctrl+C at an empty prompt.
        // Later, a repeated interrupt presses again in case the first key
        // did not take.
        if (agent.interrupt != .none and now_ms - agent.interrupt_pressed_at_ms < agent_types.interrupt_repress_ms) {
            return client_request.complete(session, request.request_id);
        }
    }

    if (agent_status.projectedStatus(model, exact) != .working) {
        return client_request.fail(session, request.request_id, .agent_not_working, "agent is not working");
    }

    const interrupt_key = model.resources.agent_manifests.interrupt(agent_status.projectedProvider(model, exact));
    if (interrupt_key == .none) {
        return client_request.fail(session, request.request_id, .interrupt_unsupported, "agent declares no interrupt key");
    }

    try pane_input.press(model, pane, interrupt_key.presses());
    // Claude Code runs no hook when its turn is interrupted. OpenCode and
    // Pi report their next state through their integrations when installed
    // (`session.status`, `agent_settled`), which replaces this report.
    // Until then the settling report keeps the agent working: see
    // `Agent.settleInterrupt` for when the turn counts as ended.
    _ = agent_status.observeReport(model, .{
        .identity = agent_identity.fromPane(pane),
        .state = .settling,
        .event = interrupted_event,
        .observed_at_ms = now_ms,
        .observed_at_ns = @intCast(std.Io.Timestamp.now(model.io, .awake).toNanoseconds()),
    });
    if (model.agents.find(exact)) |agent| {
        agent.interrupt = .pending;
        agent.interrupt_pressed_at_ms = now_ms;
    }

    try client_request.complete(session, request.request_id);
}

/// Clears the draft an interrupted agent put back in its composer, so the
/// turn can settle and the next prompt is not appended to the old one.
/// Claude Code restores a prompt it had not answered yet; its interrupt key,
/// Ctrl+C, clears the input once nothing runs, and exits only on a second
/// press at an empty prompt. The key is pressed once per interrupt, and
/// never into a pane a person has focused since: the text may be theirs.
///
/// ```zig
/// try agent_control.clearRestoredDraft(model, pane);
/// ```
pub fn clearRestoredDraft(model: *RuntimeModel, pane: *Pane) !void {
    const agent = model.agents.find(pane.key()) orelse return;
    if (agent.interrupt != .pending) {
        return;
    }

    const provider = agent_status.projectedProvider(model, pane.key());
    if (!prompt_scan.showsRestoredDraft(&pane.terminal, provider)) {
        return;
    }

    if (focusedByClient(model, pane.id)) {
        return;
    }

    agent.interrupt = .draft_cleared;
    agent.interrupt_pressed_at_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
    try pane_input.press(model, pane, model.resources.agent_manifests.interrupt(provider).presses());
}

/// Whether `pane_id` is the focused pane of the active tab of any attached
/// interactive client, where a person is presumably typing.
///
/// ```zig
/// if (agent_control.focusedByClient(model, pane.id)) return refuse();
/// ```
pub fn focusedByClient(model: *const RuntimeModel, pane_id: core.PaneId) bool {
    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;
        if (session.role != .ui or !session.active()) {
            continue;
        }

        const focused = model.client_layouts.focusedPane(session.delivery.client_identity) orelse continue;
        if (focused == pane_id) {
            return true;
        }
    }

    return false;
}

/// Writes the line that names the pane a prompt comes from, so the agent
/// receiving it knows a person did not type it.
///
/// ```zig
/// const line = agent_control.senderLine(model, sender, &buffer);
/// ```
pub fn senderLine(model: *const RuntimeModel, sender: core.PaneId, buffer: *[max_sender_line_bytes]u8) []const u8 {
    const name = senderName(model, sender);
    return std.fmt.bufPrint(buffer, "[telar: from {s}, pane {d}] ", .{ name, core.raw(sender) }) catch
        std.fmt.bufPrint(buffer, "[telar: from pane {d}] ", .{core.raw(sender)}) catch unreachable;
}

/// The worktree branch the sending pane works in, else its workspace name.
fn senderName(model: *const RuntimeModel, sender: core.PaneId) []const u8 {
    const pane = model.panes.resolveControlConst(.{ .id = sender, .generation = 0 }) orelse return "a telar pane";
    const workspace_id = switch (pane.location.workspace) {
        .workspace => |id| id,
        .worktree => return "a worktree",
    };

    if (model.worktrees.slotOfWorkspace(workspace_id)) |slot| {
        return prefix(model.worktrees.branchAt(slot));
    }

    const name = model.workspaces.workspaceName(pane.location.workspace) orelse return "a telar pane";
    return prefix(name);
}

/// The start of a sender name, cut on a UTF-8 boundary.
fn prefix(name: []const u8) []const u8 {
    return core.utf8Prefix(name, max_sender_name_bytes);
}

test "a sender name is cut on a UTF-8 boundary" {
    const name = "a" ** (max_sender_name_bytes - 1) ++ "é";
    try std.testing.expectEqualStrings("a" ** (max_sender_name_bytes - 1), prefix(name));
    try std.testing.expectEqualStrings("short", prefix("short"));
}
