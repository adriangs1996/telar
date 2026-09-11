const PaneType = @import("../../../../pane/Pane.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const CacheType = @import("../../../../process/Cache.zig");
const Work = @This();

pane: *PaneType,
current_size: TerminalSizeType,
process_cache: CacheType,
