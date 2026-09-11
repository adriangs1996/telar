const id_module = @import("../id.zig");
/// Deletes one exact history entry.
const DeleteHistory = @This();

request_id: id_module.RequestId,
id: u64,
