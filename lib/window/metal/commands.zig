const objc = @import("objc");
const Object = objc.Object;
const objects = @import("objects.zig");
const LoadAction = @import("LoadAction.zig").LoadAction;
const StoreAction = @import("StoreAction.zig").StoreAction;
const ClearColor = @import("ClearColor.zig").ClearColor;
const RenderStages = @import("RenderStages.zig").RenderStages;
const Draw = @import("Draw.zig");

/// Owned descriptor; release after use. Example: `const descriptor = try newCommitOptions();`.
pub fn newCommitOptions() !Object {
    return objects.create("MTL4CommitOptions");
}

/// Owned descriptor; release after use. Example: `const descriptor = try newRenderPass();`.
pub fn newRenderPass() !Object {
    return objects.create("MTL4RenderPassDescriptor");
}

/// Example: `commands.setTexture(object, value)`.
pub fn setTexture(self: Object, value: ?Object) void {
    self.msgSend(void, "setTexture:", .{if (value) |texture| texture.value else @as(objc.c.id, null)});
}

/// Example: `commands.setLoadAction(object, value)`.
pub fn setLoadAction(self: Object, value: LoadAction) void {
    self.msgSend(void, "setLoadAction:", .{@intFromEnum(value)});
}

/// Example: `commands.setStoreAction(object, value)`.
pub fn setStoreAction(self: Object, value: StoreAction) void {
    self.msgSend(void, "setStoreAction:", .{@intFromEnum(value)});
}

/// Example: `commands.setClearColor(object, value)`.
pub fn setClearColor(self: Object, value: ClearColor) void {
    self.msgSend(void, "setClearColor:", .{value});
}

/// Example: `commands.setRenderPipeline(object, value)`.
pub fn setRenderPipeline(self: Object, value: Object) void {
    self.msgSend(void, "setRenderPipelineState:", .{value});
}

/// Example: `commands.addResidencySet(object, value)`.
pub fn addResidencySet(self: Object, value: Object) void {
    self.msgSend(void, "addResidencySet:", .{value});
}

/// Example: `commands.removeResidencySet(object, value)`.
pub fn removeResidencySet(self: Object, value: Object) void {
    self.msgSend(void, "removeResidencySet:", .{value});
}

/// Example: `commands.begin(object, value)`.
pub fn begin(self: Object, value: Object) void {
    self.msgSend(void, "beginCommandBufferWithAllocator:", .{value});
}

/// Example: `commands.waitForDrawable(object, value)`.
pub fn waitForDrawable(self: Object, value: Object) void {
    self.msgSend(void, "waitForDrawable:", .{value});
}

/// Example: `commands.signalDrawable(object, value)`.
pub fn signalDrawable(self: Object, value: Object) void {
    self.msgSend(void, "signalDrawable:", .{value});
}

/// Example: `commands.resetAllocator(object)`.
pub fn resetAllocator(self: Object) void {
    self.msgSend(void, "reset", .{});
}

/// Example: `commands.end(object)`.
pub fn end(self: Object) void {
    self.msgSend(void, "endCommandBuffer", .{});
}

/// Example: `commands.endEncoding(object)`.
pub fn endEncoding(self: Object) void {
    self.msgSend(void, "endEncoding", .{});
}

/// Borrowed attachment. Example: `commands.colorAttachment(pass, 0)`.
pub fn colorAttachment(self: Object, index: usize) Object {
    const attachments = self.msgSend(Object, "colorAttachments", .{});
    return attachments.msgSend(Object, "objectAtIndexedSubscript:", .{index});
}

/// Borrowed encoder; end encoding before ending commands. Example: `commands.renderEncoder(buffer, pass)`.
pub fn renderEncoder(self: Object, pass: Object) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "renderCommandEncoderWithDescriptor:", .{pass}));
}

/// Example: `commands.setArgumentTable(encoder, table, .{ .vertex = true })`.
pub fn setArgumentTable(self: Object, table: Object, stages: RenderStages) void {
    self.msgSend(void, "setArgumentTable:atStages:", .{ table, @as(usize, @bitCast(stages)) });
}

/// Example: `commands.draw(encoder, .{ .vertex_count = 3 })`.
pub fn draw(self: Object, value: Draw) void {
    self.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", .{ @intFromEnum(value.primitive), value.vertex_start, value.vertex_count, value.instance_count, value.base_instance });
}

/// Metal 4 does not retain referenced resources; caller owns their lifetime. Example: `commands.commit(queue, &.{buffer.value}, options)`.
pub fn commit(self: Object, buffers: []const objc.c.id, options: Object) void {
    self.msgSend(void, "commit:count:options:", .{ buffers.ptr, buffers.len, options });
}

/// Pass a Metal feedback block, re-register for every commit. Example: `commands.addFeedbackHandler(options, &block)`.
pub fn addFeedbackHandler(self: Object, block: *const anyopaque) void {
    self.msgSend(void, "addFeedbackHandler:", .{block});
}

/// Borrowed NSError, valid during callback. Example: `commands.feedbackError(feedback)`.
pub fn feedbackError(self: Object) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "error", .{}));
}

/// Native GPU timestamp in seconds. Example: `commands.gpuStartTime(feedback)`.
pub fn gpuStartTime(self: Object) f64 {
    return objects.double(self, "GPUStartTime");
}

/// Native GPU timestamp in seconds. Example: `commands.gpuEndTime(feedback)`.
pub fn gpuEndTime(self: Object) f64 {
    return objects.double(self, "GPUEndTime");
}
