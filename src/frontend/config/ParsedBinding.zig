const model = @import("model.zig");
const ParsedBinding = @This();

binding: model.ConfiguredBinding,
prefixed: bool,
