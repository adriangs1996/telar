//! Bounded capture of relayed HTTP exchanges: each direction's head and
//! de-framed body within a shared byte quota, halves paired by exchange
//! key, and bodies decoded from their content encoding. The owner of an
//! exchange is the caller's type; nothing here reads it.

pub const Buffer = @import("Buffer.zig");
pub const Config = @import("Config.zig");
pub const GenericHalf = @import("GenericHalf.zig").Type;
pub const GenericJoiner = @import("GenericJoiner.zig").Type;
pub const Key = @import("Key.zig");
pub const Quota = @import("Quota.zig");
pub const Reservation = @import("Reservation.zig");
pub const Truncation = @import("Truncation.zig");
pub const buffer_support = @import("buffer_support.zig");
pub const decode = @import("decode.zig");

test {
    _ = @import("Buffer.zig");
    _ = @import("Config.zig");
    _ = @import("GenericHalf.zig");
    _ = @import("GenericJoiner.zig");
    _ = @import("Key.zig");
    _ = @import("Quota.zig");
    _ = @import("Reservation.zig");
    _ = @import("Truncation.zig");
    _ = @import("buffer_support.zig");
    _ = @import("decode.zig");
}
