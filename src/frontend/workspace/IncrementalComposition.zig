const MultiplexerModel = @import("telar-client").MultiplexerModel;
const ScreenType = @import("../presentation/Screen.zig");
const BufferType = @import("telar-core").Buffer;
const CopyProjection = @import("telar-client").CopyProjection;
const IncrementalComposition = @This();

model: *const MultiplexerModel,
screen: *ScreenType,
target: *BufferType,
previous_copy: ?CopyProjection,
copy_changed: bool,
