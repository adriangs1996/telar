/// Defines how one service starts its worker and tears it down.
///
/// ```zig
/// const port: Port(State, Worker) = .{ ... };
/// ```
pub fn Type(comptime StateType: type, comptime WorkerType: type) type {
    return struct {
        start: *const fn (*StateType) anyerror!WorkerType,
        close: *const fn (*StateType) void,
        join: *const fn (*StateType, *WorkerType) void,
        destroy: *const fn (*StateType) void,
    };
}
