const data = @import("model");
const client = @import("telar-client");
const ActionCapture = @This();

value: ?data.actions.Action = null,
keys: usize = 0,

pub fn action(self: *ActionCapture, value: data.actions.Action) !data.keybind.Control {
    self.value = value;
    return .continue_routing;
}

pub fn key(self: *ActionCapture, _: data.Key) !void {
    self.keys += 1;
}

pub fn forward(_: *ActionCapture, _: []const u8) !void {}
