//! Captured exchanges as telar owns them: the capture library's types over
//! the protocol of the tunnel that relayed them.
const exchangecapture = @import("exchangecapture");
const Owner = @import("Owner.zig");
const GenericJoiner = exchangecapture.GenericJoiner;

pub const Joiner = GenericJoiner(Owner);
pub const Half = Joiner.Half;
pub const Exchange = Joiner.Exchange;
