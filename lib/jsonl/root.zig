//! Bounded JSON-lines streams from a child process: whole records up to a
//! line bound, oversized output fields truncated in place without breaking
//! the JSON, and total accessors over parsed values.

pub const OutputFrame = @import("OutputFrame.zig");
pub const Stream = @import("Stream.zig");
pub const json = @import("json.zig");
pub const limits = @import("limits.zig");
pub const field = json.field;
pub const string = json.string;
pub const is = json.is;
pub const encode = json.encode;

test {
    _ = @import("OutputFrame.zig");
    _ = @import("Stream.zig");
    _ = @import("json.zig");
    _ = @import("limits.zig");
}
