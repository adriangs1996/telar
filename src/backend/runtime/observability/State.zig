const SinkType = @import("telar-core").Sink;
const telemetry = @import("telemetry.zig");
const std = @import("std");
const State = @This();

sink: SinkType = .{},
line: [telemetry.max_line_bytes]u8 = undefined,
write_pending: bool = false,

/// Creates the runtime-owned telemetry sink and its bounded line buffer.
///
/// ```zig
/// var state = State.init(io, endpoint, "runtime");
/// ```
pub fn init(io: std.Io, endpoint: []const u8, suffix: []const u8) State {
    return .{ .sink = SinkType.init(io, endpoint, suffix) };
}

/// Closes the sink without invalidating an in-flight write completion.
///
/// ```zig
/// state.deinit(io);
/// ```
pub fn deinit(state: *State, io: std.Io) void {
    state.sink.deinit(io);
}

/// Reports whether telemetry can accept another scheduled sample.
///
/// ```zig
/// if (!state.available()) {
///     return;
/// }
/// ```
pub fn available(state: *const State) bool {
    return state.sink.available();
}

/// Returns the fixed storage reused by consecutive telemetry samples.
///
/// ```zig
/// const line = try formatRuntimeTelemetry(state.buffer(), sample);
/// ```
pub fn buffer(state: *State) []u8 {
    return &state.line;
}

/// Reports whether the shared line buffer belongs to a write actor.
///
/// ```zig
/// if (state.writePending()) {
///     return;
/// }
/// ```
pub fn writePending(state: *const State) bool {
    return state.write_pending;
}

/// Borrows the shared line buffer for one asynchronous sink write.
///
/// ```zig
/// state.beginWrite();
/// ```
pub fn beginWrite(state: *State) void {
    std.debug.assert(!state.write_pending);
    state.write_pending = true;
}

/// Rolls back a write actor that could not be scheduled.
///
/// ```zig
/// state.cancelWrite();
/// ```
pub fn cancelWrite(state: *State) void {
    std.debug.assert(state.write_pending);
    state.write_pending = false;
}

/// Releases the shared line buffer and decides whether a failed actor must
/// retire the sink. The buffer becomes reusable before either action is
/// returned to the runtime.
///
/// ```zig
/// const action = state.finishWrite(result);
/// ```
pub fn finishWrite(state: *State, result: anyerror!void) telemetry.WriteCompletion {
    std.debug.assert(state.write_pending);
    state.write_pending = false;

    result catch return .disable_sink;
    return .ready;
}

/// Writes the borrowed line through the development diagnostics sink.
///
/// ```zig
/// try state.write(io, line);
/// ```
pub fn write(state: *State, io: std.Io, line: []const u8) !void {
    std.debug.assert(state.write_pending);
    try state.sink.write(io, line);
}
