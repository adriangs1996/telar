const core = @import("telar-core");
const Pane = @import("../../pane/Pane.zig");
const Cache = @import("../../process/Cache.zig");
const Work = @This();

pane: *Pane,
current_size: core.TerminalSize,
process_cache: Cache,
