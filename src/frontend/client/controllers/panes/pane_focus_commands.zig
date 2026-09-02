//! Applies a runtime-routed focus request to this client's disposable layout.

const core = @import("telar-core");
const workspace = @import("../../../workspace/root.zig");
const runtime_transport = @import("../../connection/runtime_transport.zig");
const pane_focus = @import("pane_focus.zig");

const Client = @import("../../client.zig");
const schema = core.schema;

const Completion = struct {
    outcome: schema.PaneFocusOutcome,
    focused_pane_id: schema.PaneId,
};

/// Revalidates the source pane, applies the directional focus, and reports the
/// result to the control connection through the runtime.
///
/// ```zig
/// try apply(client, command);
/// ```
pub fn apply(client: *Client, command: schema.PaneFocusCommand) !void {
    const current = client.model.planPaneInput(.focused);
    if (current == null or current.?.pane_id != command.pane_id) {
        return complete(client, command, .{ .outcome = .source_not_focused, .focused_pane_id = .invalid });
    }

    var use_case = pane_focus.handler(client);
    const focus = try use_case.execute(.{
        .target = .{ .direction = direction(command.direction) },
        .area = client.view.workbench(),
    });
    if (focus) |changed| {
        return complete(client, command, .{ .outcome = .focused, .focused_pane_id = changed.focused });
    }

    return complete(client, command, .{ .outcome = .no_neighbor, .focused_pane_id = command.pane_id });
}

fn complete(client: *Client, command: schema.PaneFocusCommand, completion: Completion) !void {
    try runtime_transport.enqueue(client, .{ .complete_pane_focus = .{
        .requester = command.requester,
        .request_id = command.request_id,
        .pane_id = command.pane_id,
        .pane_generation = command.pane_generation,
        .outcome = completion.outcome,
        .focused_pane_id = completion.focused_pane_id,
    } });
}

fn direction(value: schema.PaneDirection) workspace.layout.Direction {
    return switch (value) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
    };
}
