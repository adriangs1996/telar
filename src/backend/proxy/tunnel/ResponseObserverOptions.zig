const HalfType = @import("../capture/Half.zig");
const ResponseObserverOptions = @This();

inspect_payload: bool,
capture_half: ?*HalfType,
