//! The copy indicator appears only after the host acknowledges these bytes.
const Id = @import("Id.zig");
const ThreadItemControl = @import("ThreadItemControl.zig");

request_id: u64,
owner: Id,
control: ThreadItemControl,
