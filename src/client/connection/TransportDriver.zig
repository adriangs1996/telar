const RuntimeTransportStateType = @import("RuntimeTransportState.zig");
/// Starts one runtime read or write on the adapter's event loop. The shared
/// transport state owns tokens and buffers; the adapter only runs the I/O and
/// delivers its completion.
const TransportDriver = @This();

context: *anyopaque,
start_read_fn: *const fn (*anyopaque, *RuntimeTransportStateType) anyerror!void,
start_send_fn: *const fn (*anyopaque, *RuntimeTransportStateType, []const u8) anyerror!void,

/// Example: `try client.transport_driver.startRead(&client.runtime_transport);`.
pub fn startRead(port: TransportDriver, state: *RuntimeTransportStateType) !void {
    return port.start_read_fn(port.context, state);
}

/// Example: `try client.transport_driver.startSend(state, payload);`.
pub fn startSend(port: TransportDriver, state: *RuntimeTransportStateType, payload: []const u8) !void {
    return port.start_send_fn(port.context, state, payload);
}
