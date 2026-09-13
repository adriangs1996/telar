const client = @import("telar-client");
const ActionCapture = @This();

value: ?client.Action = null,
keys: usize = 0,

pub fn action(capture: *ActionCapture, value: client.Action) !client.Control {
    capture.value = value;
    return .continue_routing;
}

pub fn key(capture: *ActionCapture, _: client.Key) !void {
    capture.keys += 1;
}

pub fn forward(_: *ActionCapture, _: []const u8) !void {}
