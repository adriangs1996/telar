/// The process where a limit was reached: the runtime itself or a client
/// that reported it.
pub const LimitOrigin = enum(u8) {
    runtime = 0,
    client = 1,
};
