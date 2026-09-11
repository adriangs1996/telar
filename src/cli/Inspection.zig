const proxy = @import("proxy.zig");
const Record = @import("Record.zig");
const Inspection = @This();

status: proxy.Status,
record: ?Record,
