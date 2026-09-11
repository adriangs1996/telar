const Composition = @This();
const Model = @import("telar-client").workspace.multiplexer.Model;
const source_namespace = @import("multiplexer.zig");
const CompositionInput = @import("CompositionInput.zig");
model: *const Model,
screen: *source_namespace.term.Screen,
input: CompositionInput,
