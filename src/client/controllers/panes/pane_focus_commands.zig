//! Applies a runtime-routed focus request to this client's disposable layout.

const Client = @import("../../AttachedClient.zig");
const PaneFocusCommandType = @import("telar-core").PaneFocusCommand;
const pane_focus = @import("pane_focus.zig");
const Completion = @import("Completion.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const PaneDirectionType = @import("telar-core").PaneDirection;
const WorkspaceLayoutSupportDirection = @import("../../workspace/layout_support.zig").Direction;

/// Revalidates the source pane, applies the directional focus, and reports the
/// result to the control connection through the runtime.
///
/// ```zig
/// try apply(client, command);
/// ```
pub fn apply(client: *Client, command: PaneFocusCommandType) !void {
    const current = client.model.planPaneInput(.focused);
    if (current == null or current.?.pane_id != command.pane_id) {
        return complete(client, command, .{ .outcome = .source_not_focused, .focused_pane_id = .invalid });
    }

    var use_case = pane_focus.handler(client);
    const focus = try use_case.execute(.{
        .target = .{ .direction = direction(command.direction) },
        .area = client.geometry().area,
    });
    if (focus) |changed| {
        return complete(client, command, .{ .outcome = .focused, .focused_pane_id = changed.focused });
    }

    return complete(client, command, .{ .outcome = .no_neighbor, .focused_pane_id = command.pane_id });
}

fn complete(client: *Client, command: PaneFocusCommandType, completion: Completion) !void {
    try runtime_transport.enqueue(client, .{ .complete_pane_focus = .{
        .requester = command.requester,
        .request_id = command.request_id,
        .pane_id = command.pane_id,
        .pane_generation = command.pane_generation,
        .outcome = completion.outcome,
        .focused_pane_id = completion.focused_pane_id,
    } });
}

fn direction(value: PaneDirectionType) WorkspaceLayoutSupportDirection {
    return switch (value) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
    };
}
