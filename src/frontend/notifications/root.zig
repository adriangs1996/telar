//! Terminal delivery plus the shared notification model.
const shared = @import("telar-client").notifications;
pub const host = @import("host.zig");
pub const Delivery = shared.Delivery;
pub const max_items = shared.max_items;
pub const max_title_bytes = shared.max_title_bytes;
pub const max_message_bytes = shared.max_message_bytes;
pub const transition_duration_ns = shared.transition_duration_ns;
pub const default_duration_ns = shared.default_duration_ns;
pub const Id = shared.Id;
pub const Level = shared.Level;
pub const Target = shared.Target;
pub const Input = shared.Input;
pub const Item = shared.Item;
pub const Center = shared.Center;
