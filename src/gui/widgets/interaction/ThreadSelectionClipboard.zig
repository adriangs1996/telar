const Owner = @import("../../host/Owner.zig");
const ThreadTextPosition = @import("ThreadTextPosition.zig");

request_id: u64,
owner: Owner,
exit_after: bool,
range: [2]ThreadTextPosition,
