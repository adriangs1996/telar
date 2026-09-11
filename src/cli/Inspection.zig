const Inspection = @This();
const source_namespace = @import("proxy.zig");
const Record = @import("Record.zig");
status: source_namespace.Status,
record: ?Record,
