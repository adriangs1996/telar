const history = @import("arguments/history.zig");
const ResolvedImport = @This();

kind: history.HistoryImportKind,
path: []const u8,
