//! Wires copy-mode pointer ownership to geometry and copy-mode effects.

const core = @import("telar-core");
const presentation = @import("../../../presentation/root.zig");
const workspace_capability = @import("../../../workspace/root.zig");
const input_application = @import("../../application/input/root.zig");
const copy_modes = @import("copy_modes.zig");

const Client = @import("../../client.zig");
const copy_mode_pointer = input_application.copy_mode_pointer;
const multiplexer = workspace_capability.multiplexer;
const term = presentation.screen;
const ui = core.ui;

const Context = struct {
    client: *Client,
    model: *multiplexer.Model,
    area: ui.Rect,
};

/// Gives copy mode first refusal for one cell-based pointer event.
///
/// ```zig
/// if (try apply(client, model, event)) return;
/// ```
pub fn apply(client: *Client, model: *multiplexer.Model, event: term.Event.Mouse) !bool {
    var context: Context = .{
        .client = client,
        .model = model,
        .area = client.view.workbench(),
    };

    var use_case: copy_mode_pointer.CopyModePointerHandler = .{
        .effects = .{
            .context = &context,
            .leave = leave,
            .vertical = vertical,
        },
    };

    const outcome = try use_case.execute(.{ .kind = event.kind }, resolve(&context, event));

    return outcome != .unowned;
}

fn resolve(context: *Context, event: term.Event.Mouse) copy_mode_pointer.Authority {
    const pane_id = context.client.model.copyModeTarget() orelse return .unowned;
    if (context.model.find(pane_id) == null) {
        return .target_missing;
    }

    const view = context.model.viewForPane(pane_id, context.area) orelse
        return .{ .owned = .{ .pointer_inside = false } };

    return .{ .owned = .{
        .pointer_inside = view.content.contains(event.x, event.y),
    } };
}

fn leave(raw_context: *anyopaque) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.leave(context.client);
}

fn vertical(raw_context: *anyopaque, delta: i32) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.vertical(context.client, delta);
}
