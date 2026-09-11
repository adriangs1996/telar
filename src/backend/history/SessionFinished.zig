const model = @import("model.zig");
const SessionFinished = @This();

id: model.SessionId,
finished_at_ms: i64,
