const data = @import("model");
const client = @import("telar-client");
const core = @import("telar-core");
const ScreenType = @import("../presentation/Screen.zig");
const IncrementalComposition = @This();

model: *const data.Model,
/// The composed tab's slot in `model.tabs`.
tab: usize,
screen: *ScreenType,
target: *core.Buffer,
previous_copy: ?client.CopyProjection,
copy_changed: bool,
