//! The headless client: the shared client without a window. It imports the client, the model
//! and core; no other adapter imports it.
pub const HeadlessClient = @import("HeadlessClient.zig");
pub const HeadlessOptions = @import("HeadlessOptions.zig");
