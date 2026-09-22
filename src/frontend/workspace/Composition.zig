const data = @import("model");
const client = @import("telar-client");
const ScreenType = @import("../presentation/Screen.zig");
const CompositionInput = @import("CompositionInput.zig");
const Composition = @This();

model: *const data.MultiplexerModel,
screen: *ScreenType,
input: CompositionInput,
