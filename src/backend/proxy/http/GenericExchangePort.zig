const std = @import("std");
const types = @import("types.zig");
/// Supplies the I/O operations needed to finish one request/response pair.
///
/// ```zig
/// const port: ExchangePort(Context) = .{
///     .io = Context.io,
///     .relay_body = Context.relayBody,
///     .relay_response = Context.relayResponse,
/// };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        io: *const fn (*Context) std.Io,
        relay_body: *const fn (*Context, types.BodyPlan) bool,
        relay_response: *const fn (*Context, types.RequestHead) ?types.ResponseHead,
    };
}
