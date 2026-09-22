const data = @import("model");
const client = @import("telar-client");
const ActionCapture = @This();

value: ?data.actions.Action = null,
keys: usize = 0,

pub fn action(capture: *ActionCapture, value: data.actions.Action) !data.keybind.Control {
    capture.value = value;
    return .continue_routing;
}

pub fn key(capture: *ActionCapture, _: data.Key) !void {
    capture.keys += 1;
}

pub fn forward(_: *ActionCapture, _: []const u8) !void {}
