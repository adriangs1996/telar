const TerminalSizeType = @import("telar-core").TerminalSize;
const CacheType = @import("../process/Cache.zig");
const HistoryObservationBorrow = @This();

current_size: TerminalSizeType,
process_cache: CacheType,
