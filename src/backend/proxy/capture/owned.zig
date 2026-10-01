//! Captured exchanges as telar owns them: the capture library's types over
//! the protocol of the tunnel that relayed them.
const core = @import("telar-core");
const exchangecapture = @import("exchangecapture");
const Owner = @import("Owner.zig");
const GenericJoiner = exchangecapture.GenericJoiner;

pub const Joiner = GenericJoiner(Owner);
pub const Half = Joiner.Half;
pub const Exchange = Joiner.Exchange;

/// Exchanges waiting for their second half in the runtime's join table.
pub const joiner_capacity_limit = core.Limit.declare("proxy.capture.joiner_capacity", "pending exchanges", Joiner.capacity);
