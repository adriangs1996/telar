const data = @import("model");
const client = @import("telar-client");
const core = @import("telar-core");
const Screen = @import("../presentation/Screen.zig");
const IncrementalComposition = @This();

model: *const data.ClientModel,
/// The composed tab's slot in `model.tabs`.
tab: usize,
screen: *Screen,
target: *core.Buffer,
previous_copy: ?client.CopyProjection,
copy_changed: bool,
