//! A client for Pi's JSONL RPC mode: one child process at a time answers
//! bounded prompts behind a request ring, and is killed when idle or broken.

pub const GenericService = @import("GenericService.zig").Type;
pub const Options = @import("Options.zig");
pub const types = @import("types.zig");

test {
    _ = @import("GenericService.zig");
    _ = @import("rpc.zig");
    _ = @import("service_tests.zig");
    _ = @import("session_support.zig");
    _ = @import("types.zig");
}
