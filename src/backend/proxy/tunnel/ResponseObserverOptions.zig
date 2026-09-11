const ResponseObserverOptions = @This();
const capture = @import("../capture/root.zig");
inspect_payload: bool,
capture_half: ?*capture.Half,
