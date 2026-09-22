const data = @import("model");
const client = @import("telar-client");
const core = @import("telar-core");
const ScreenType = @import("../presentation/Screen.zig");
const IncrementalComposition = @This();

model: *const data.MultiplexerModel,
screen: *ScreenType,
target: *core.Buffer,
previous_copy: ?client.CopyProjection,
copy_changed: bool,
