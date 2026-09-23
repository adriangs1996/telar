const data = @import("model");
const client = @import("telar-client");
const Screen = @import("../presentation/Screen.zig");
const CompositionInput = @import("CompositionInput.zig");
const Composition = @This();

model: *const data.ClientModel,
/// The composed tab's slot in `model.tabs`.
tab: usize,
screen: *Screen,
input: CompositionInput,
