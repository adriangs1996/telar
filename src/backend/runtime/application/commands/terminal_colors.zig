//! Commits one client's terminal defaults before updating its owned workspaces.

const core = @import("telar-core");
const client = @import("../../client/root.zig");

pub const Handler = @import("GenericHandler.zig").Type;
