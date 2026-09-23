const core = @import("telar-core");
const Cache = @import("../process/Cache.zig");
const HistoryObservationBorrow = @This();

current_size: core.TerminalSize,
process_cache: Cache,
