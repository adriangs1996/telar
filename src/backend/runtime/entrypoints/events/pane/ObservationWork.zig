const core = @import("telar-core");
const PaneType = @import("../../../../pane/Pane.zig");
const CacheType = @import("../../../../process/Cache.zig");
const Work = @This();

pane: *PaneType,
current_size: core.TerminalSize,
process_cache: CacheType,
