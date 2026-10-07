//! Bounded state for the command-suggestion palette: at most one request
//! in flight and one suggested line. Only the awaited reply lands; editing
//! the request text discards a suggestion so Enter asks again.

pub const Phase = enum {
    /// Nothing asked yet, or the request text changed since the last reply.
    idle,
    waiting,
    ready,
    failed,
};
