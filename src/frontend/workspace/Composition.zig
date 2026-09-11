const MultiplexerModel = @import("telar-client").MultiplexerModel;
const ScreenType = @import("../presentation/Screen.zig");
const CompositionInput = @import("CompositionInput.zig");
const Composition = @This();

model: *const MultiplexerModel,
screen: *ScreenType,
input: CompositionInput,
