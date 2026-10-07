const objc = @import("objc");
const Object = objc.Object;
const objects = @import("objects.zig");
const PixelFormat = @import("PixelFormat.zig").PixelFormat;
const LanguageVersion = @import("LanguageVersion.zig").LanguageVersion;
const BlendFactor = @import("BlendFactor.zig").BlendFactor;
const BlendOperation = @import("BlendOperation.zig").BlendOperation;
const BlendState = @import("BlendState.zig").BlendState;

/// Owned descriptor; release after use. Example: `const descriptor = try newCompilerDescriptor();`.
pub fn newCompilerDescriptor() !Object {
    return objects.create("MTL4CompilerDescriptor");
}

/// Owned descriptor; release after use. Example: `const descriptor = try newLibraryDescriptor();`.
pub fn newLibraryDescriptor() !Object {
    return objects.create("MTL4LibraryDescriptor");
}

/// Owned descriptor; release after use. Example: `const descriptor = try newCompileOptions();`.
pub fn newCompileOptions() !Object {
    return objects.create("MTLCompileOptions");
}

/// Owned descriptor; release after use. Example: `const descriptor = try newFunctionDescriptor();`.
pub fn newFunctionDescriptor() !Object {
    return objects.create("MTL4LibraryFunctionDescriptor");
}

/// Owned descriptor; release after use. Example: `const descriptor = try newRenderDescriptor();`.
pub fn newRenderDescriptor() !Object {
    return objects.create("MTL4RenderPipelineDescriptor");
}

/// Example: `pipeline.setLanguageVersion(descriptor, value)`.
pub fn setLanguageVersion(self: Object, value: LanguageVersion) void {
    self.msgSend(void, "setLanguageVersion:", .{@intFromEnum(value)});
}

/// Example: `pipeline.setOptions(descriptor, value)`.
pub fn setOptions(self: Object, value: Object) void {
    self.msgSend(void, "setOptions:", .{value});
}

/// Example: `pipeline.setSource(descriptor, value)`.
pub fn setSource(self: Object, value: Object) void {
    self.msgSend(void, "setSource:", .{value});
}

/// Example: `pipeline.setName(descriptor, value)`.
pub fn setName(self: Object, value: Object) void {
    self.msgSend(void, "setName:", .{value});
}

/// Example: `pipeline.setLibrary(descriptor, value)`.
pub fn setLibrary(self: Object, value: Object) void {
    self.msgSend(void, "setLibrary:", .{value});
}

/// Example: `pipeline.setVertexFunction(descriptor, value)`.
pub fn setVertexFunction(self: Object, value: Object) void {
    self.msgSend(void, "setVertexFunctionDescriptor:", .{value});
}

/// Example: `pipeline.setFragmentFunction(descriptor, value)`.
pub fn setFragmentFunction(self: Object, value: Object) void {
    self.msgSend(void, "setFragmentFunctionDescriptor:", .{value});
}

/// Example: `pipeline.setPixelFormat(descriptor, value)`.
pub fn setPixelFormat(self: Object, value: PixelFormat) void {
    self.msgSend(void, "setPixelFormat:", .{@intFromEnum(value)});
}

/// Example: `pipeline.setBlendingState(descriptor, value)`.
pub fn setBlendingState(self: Object, value: BlendState) void {
    self.msgSend(void, "setBlendingState:", .{@intFromEnum(value)});
}

/// Example: `pipeline.setSourceRGBBlendFactor(descriptor, value)`.
pub fn setSourceRGBBlendFactor(self: Object, value: BlendFactor) void {
    self.msgSend(void, "setSourceRGBBlendFactor:", .{@intFromEnum(value)});
}

/// Example: `pipeline.setDestinationRGBBlendFactor(descriptor, value)`.
pub fn setDestinationRGBBlendFactor(self: Object, value: BlendFactor) void {
    self.msgSend(void, "setDestinationRGBBlendFactor:", .{@intFromEnum(value)});
}

/// Example: `pipeline.setSourceAlphaBlendFactor(descriptor, value)`.
pub fn setSourceAlphaBlendFactor(self: Object, value: BlendFactor) void {
    self.msgSend(void, "setSourceAlphaBlendFactor:", .{@intFromEnum(value)});
}

/// Example: `pipeline.setDestinationAlphaBlendFactor(descriptor, value)`.
pub fn setDestinationAlphaBlendFactor(self: Object, value: BlendFactor) void {
    self.msgSend(void, "setDestinationAlphaBlendFactor:", .{@intFromEnum(value)});
}

/// Example: `pipeline.setRGBBlendOperation(descriptor, value)`.
pub fn setRGBBlendOperation(self: Object, value: BlendOperation) void {
    self.msgSend(void, "setRgbBlendOperation:", .{@intFromEnum(value)});
}

/// Example: `pipeline.setAlphaBlendOperation(descriptor, value)`.
pub fn setAlphaBlendOperation(self: Object, value: BlendOperation) void {
    self.msgSend(void, "setAlphaBlendOperation:", .{@intFromEnum(value)});
}

/// Owned library; NSError is borrowed. Example: `pipeline.newLibrary(compiler, descriptor, &failure)`.
pub fn newLibrary(self: Object, descriptor: Object, failure: *objc.c.id) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "newLibraryWithDescriptor:error:", .{ descriptor, failure }));
}

/// Owned pipeline; NSError is borrowed. Example: `pipeline.newRenderPipeline(compiler, descriptor, &failure)`.
pub fn newRenderPipeline(self: Object, descriptor: Object, failure: *objc.c.id) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "newRenderPipelineStateWithDescriptor:compilerTaskOptions:error:", .{ descriptor, @as(objc.c.id, null), failure }));
}

/// Borrowed attachment. Example: `pipeline.colorAttachment(descriptor, 0)`.
pub fn colorAttachment(self: Object, index: usize) Object {
    const attachments = self.msgSend(Object, "colorAttachments", .{});
    return attachments.msgSend(Object, "objectAtIndexedSubscript:", .{index});
}
