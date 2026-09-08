const client_model = @import("../../model/root.zig");

const ToggleAgentModeHandler = @This();

model: *client_model.Model,

pub fn execute(self: *ToggleAgentModeHandler) void {
    self.model.toggleAgentMode();
}
