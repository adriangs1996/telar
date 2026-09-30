//! What `limit_list` answers from: the runtime's own limits, the ones its
//! clients reported, and how many reports it refused.
const id = @import("../id.zig");
const LimitReaches = @import("../../LimitReaches.zig");

request_id: id.RequestId,
runtime: *const LimitReaches,
clients: *const LimitReaches,
/// Client reports refused because a client sent too many at once.
refused_reports: u64,
