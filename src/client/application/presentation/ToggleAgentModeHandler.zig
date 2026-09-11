const ModelType = @import("../../model/Model.zig");

const ToggleAgentModeHandler = @This();

model: *ModelType,

pub fn execute(self: *ToggleAgentModeHandler) void {
    self.model.toggleAgentMode();
}
