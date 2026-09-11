const ResponseObserver = @import("ResponseObserver.zig");
const Slot = @This();

stream_id: u32 = 0,
response: ?*ResponseObserver = null,
