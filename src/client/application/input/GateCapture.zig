const ModelType = @import("../../model/Model.zig");
const OpenNamePromptHandler = @import("OpenNamePromptHandler.zig");
const GateCapture = @This();

blocked: bool = false,
calls: usize = 0,

pub fn handler(capture: *GateCapture, model: *ModelType) OpenNamePromptHandler {
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
