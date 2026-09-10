const client_model = @import("../../root.zig").model;

const ToggleAgentModeHandler = @This();

model: *client_model.Model,

pub fn execute(self: *ToggleAgentModeHandler) void {
    self.model.toggleAgentMode();
}
