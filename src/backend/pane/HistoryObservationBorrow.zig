const HistoryObservationBorrow = @This();
const source_namespace = @import("root.zig");
const agent_process = @import("../process/root.zig");
current_size: source_namespace.schema.TerminalSize,
process_cache: agent_process.Cache,
