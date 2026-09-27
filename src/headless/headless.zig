//! The headless client: the shared client without a window, for tests and
//! tools (docs/flows/headless-client.md). It imports the client, the model
//! and core; no other adapter imports it.
pub const HeadlessClient = @import("HeadlessClient.zig");
pub const HeadlessOptions = @import("HeadlessOptions.zig");

test {
    _ = @import("input_protocol.zig");
    _ = @import("Trace.zig");
    _ = @import("HeadlessOptions.zig");
}
