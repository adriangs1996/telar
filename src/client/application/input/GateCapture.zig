const GateCapture = @This();
const client_model = @import("../../root.zig").model;
const OpenNamePromptHandler = @import("OpenNamePromptHandler.zig");
blocked: bool = false,
calls: usize = 0,

pub fn handler(capture: *GateCapture, model: *client_model.Model) OpenNamePromptHandler {
    return .{
        .model = model,
        .workspace_creation = .{
            .context = capture,
            .pending = pending,
        },
    };
}

fn pending(context: *anyopaque) bool {
    const capture: *GateCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;

    return capture.blocked;
}
