//! Internal Metal 4 bindings used by the macOS canvas.
//! The build grants this module only to the window implementation and native tests.
const objc = @import("objc");
const device = @import("device.zig");
const resources = @import("resources.zig");
const pipeline = @import("pipeline.zig");
const commands = @import("commands.zig");
const layer = @import("layer.zig");
const objects = @import("objects.zig");
const ResourceOptions = @import("ResourceOptions.zig").ResourceOptions;

// Handles and lifetime tools required by callers and native feedback.
pub const Object = objc.Object;
pub const Id = objc.c.id;
pub const AutoreleasePool = objc.AutoreleasePool;
pub const GenericFeedbackBlock = @import("GenericFeedbackBlock.zig").Type;
// Values required to describe public operations, not a catalog of Metal types.
pub const TextureOptions = @import("TextureOptions.zig");
pub const PipelineOptions = @import("PipelineOptions.zig");
pub const LayerOptions = @import("LayerOptions.zig");
pub const Size = @import("Size.zig").Size;
pub const Region = @import("Region.zig").Region;
pub const ClearColor = @import("ClearColor.zig").ClearColor;
pub const RenderStages = @import("RenderStages.zig").RenderStages;
pub const Draw = @import("Draw.zig");

/// Owned Metal 4 device, or an explicit unsupported-device error. Example: `const gpu = try metal.createDevice();`.
pub fn createDevice() !Object {
    const gpu = device.create() orelse return error.NoMetalDevice;
    errdefer gpu.release();
    if (!device.supportsFamily(gpu, .metal4)) {
        return error.Metal4Unsupported;
    }

    return gpu;
}

/// Owned queue. Example: `const queue = try metal.createCommandQueue(gpu);`.
pub fn createCommandQueue(gpu: Object) !Object {
    return device.newCommandQueue(gpu) orelse error.QueueCreationFailed;
}

/// Owned reusable command buffer. Example: `const buffer = try metal.createCommandBuffer(gpu);`.
pub fn createCommandBuffer(gpu: Object) !Object {
    return device.newCommandBuffer(gpu) orelse error.CommandCreationFailed;
}

/// Owned command memory. Example: `const allocator = try metal.createCommandAllocator(gpu);`.
pub fn createCommandAllocator(gpu: Object) !Object {
    return device.newCommandAllocator(gpu) orelse error.AllocatorCreationFailed;
}

/// Owned Metal 4 compiler; failure receives a borrowed NSError. Example: `const compiler = try metal.createCompiler(gpu, &failure);`.
pub fn createCompiler(gpu: Object, failure: *Id) !Object {
    failure.* = null;
    const descriptor = try pipeline.newCompilerDescriptor();
    defer descriptor.release();
    return device.newCompiler(gpu, descriptor, failure) orelse error.CompilerCreationFailed;
}

/// Compile UTF-8 MSL 4.0 into an owned library. Example: `const library = try metal.compileLibrary(compiler, source, &failure);`.
pub fn compileLibrary(compiler: Object, source: []const u8, failure: *Id) !Object {
    failure.* = null;
    const text = try objects.string(source);
    defer text.release();
    const options = try pipeline.newCompileOptions();
    defer options.release();
    pipeline.setLanguageVersion(options, .v4_0);
    const descriptor = try pipeline.newLibraryDescriptor();
    defer descriptor.release();
    pipeline.setSource(descriptor, text);
    pipeline.setOptions(descriptor, options);
    return pipeline.newLibrary(compiler, descriptor, failure) orelse error.LibraryCompilationFailed;
}

/// Owned pipeline; entry points and blend choices are caller-supplied. Example: `const state = try metal.createRenderPipeline(compiler, library, options, &failure);`.
pub fn createRenderPipeline(compiler: Object, library: Object, options: PipelineOptions, failure: *Id) !Object {
    failure.* = null;
    const vertex = try functionDescriptor(library, options.vertex);
    defer vertex.release();
    const fragment = try functionDescriptor(library, options.fragment);
    defer fragment.release();
    const descriptor = try pipeline.newRenderDescriptor();
    defer descriptor.release();

    pipeline.setVertexFunction(descriptor, vertex);
    pipeline.setFragmentFunction(descriptor, fragment);
    const color = pipeline.colorAttachment(descriptor, 0);
    pipeline.setPixelFormat(color, options.format);

    if (options.blend) |blend| {
        pipeline.setBlendingState(color, .enabled);
        pipeline.setSourceRGBBlendFactor(color, blend.source_rgb);
        pipeline.setDestinationRGBBlendFactor(color, blend.destination_rgb);
        pipeline.setSourceAlphaBlendFactor(color, blend.source_alpha);
        pipeline.setDestinationAlphaBlendFactor(color, blend.destination_alpha);
        pipeline.setRGBBlendOperation(color, blend.rgb_operation);
        pipeline.setAlphaBlendOperation(color, blend.alpha_operation);
    }

    return pipeline.newRenderPipeline(compiler, descriptor, failure) orelse error.PipelineCreationFailed;
}

fn functionDescriptor(library: Object, name: []const u8) !Object {
    const descriptor = try pipeline.newFunctionDescriptor();
    errdefer descriptor.release();
    const text = try objects.string(name);
    defer text.release();
    pipeline.setLibrary(descriptor, library);
    pipeline.setName(descriptor, text);
    return descriptor;
}

/// Owned 2D texture. Example: `const texture = try metal.createTexture(gpu, options);`.
pub fn createTexture(gpu: Object, options: TextureOptions) !Object {
    if (options.size.depth != 1) {
        return error.UnsupportedTextureType;
    }

    const descriptor = try resources.newTextureDescriptor();
    defer descriptor.release();
    resources.setWidth(descriptor, options.size.width);
    resources.setHeight(descriptor, options.size.height);
    resources.setPixelFormat(descriptor, options.format);
    resources.setStorageMode(descriptor, options.storage);
    resources.setTextureUsage(descriptor, options.usage);

    return resources.newTexture(gpu, descriptor) orelse error.TextureCreationFailed;
}

/// Owned buffer with caller-selected storage. Example: `const buffer = try metal.createBuffer(gpu, byte_count, .shared);`.
pub fn createBuffer(gpu: Object, byte_count: usize, storage: ResourceOptions) !Object {
    return resources.newBuffer(gpu, byte_count, storage) orelse error.BufferCreationFailed;
}

/// Borrowed CPU mapping, absent for inaccessible storage. Synchronization belongs to the caller.
/// Example: `const bytes = metal.bufferBytes(buffer) orelse return error.BufferNotShared;`.
pub fn bufferBytes(buffer: Object) ?[]u8 {
    const bytes = resources.contents(buffer) orelse return null;
    return bytes[0..resources.length(buffer)];
}

/// Query the 2D texture's extent. Example: `const size = metal.textureSize(texture);`.
pub fn textureSize(texture: Object) Size {
    return .{ .width = resources.width(texture), .height = resources.height(texture) };
}

/// Caller validates the source extent and waits for prior GPU reads. Example: `metal.uploadTexture(texture, region, 0, pixels.ptr, stride)`.
pub fn uploadTexture(texture: Object, region: Region, level: usize, bytes: [*]const u8, stride: usize) void {
    resources.replaceRegion(texture, region, level, bytes, stride);
}

/// Owned argument table sized for the caller's shader. Example: `const table = try metal.createArgumentTable(gpu, 2, 1, &failure);`.
pub fn createArgumentTable(gpu: Object, buffer_count: usize, texture_count: usize, failure: *Id) !Object {
    failure.* = null;
    const descriptor = try resources.newArgumentDescriptor();
    defer descriptor.release();
    resources.setMaxBufferBindCount(descriptor, buffer_count);
    resources.setMaxTextureBindCount(descriptor, texture_count);
    return device.newArgumentTable(gpu, descriptor, failure) orelse error.ArgumentsCreationFailed;
}

/// Bind a buffer's GPU address; keep the buffer alive through consumption. Example: `metal.bindBuffer(table, buffer, 0)`.
pub fn bindBuffer(table: Object, buffer: Object, index: usize) void {
    resources.setAddress(table, resources.gpuAddress(buffer), index);
}

/// Bind a texture's GPU id; residency and retention remain the caller's responsibility. Example: `metal.bindTexture(table, texture, 0)`.
pub fn bindTexture(table: Object, texture: Object, index: usize) void {
    resources.setTexture(table, resources.gpuResourceID(texture), index);
}

/// Owned residency set. Example: `const set = try metal.createResidencySet(gpu, capacity, &failure);`.
pub fn createResidencySet(gpu: Object, capacity: usize, failure: *Id) !Object {
    failure.* = null;
    const descriptor = try resources.newResidencyDescriptor();
    defer descriptor.release();
    resources.setInitialCapacity(descriptor, capacity);
    return device.newResidencySet(gpu, descriptor, failure) orelse error.ResidencyCreationFailed;
}

/// Stage an allocation for residency. Example: `metal.addAllocation(set, texture)`.
pub fn addAllocation(set: Object, allocation: Object) void {
    resources.addAllocation(set, allocation);
}

/// Stage removal after GPU consumption. Example: `metal.removeAllocation(set, texture)`.
pub fn removeAllocation(set: Object, allocation: Object) void {
    resources.removeAllocation(set, allocation);
}

/// Stage removal of every allocation after consumption. Example: `metal.clearResidency(set)`.
pub fn clearResidency(set: Object) void {
    resources.removeAllAllocations(set);
}

/// Commit staged residency changes. Example: `metal.commitResidency(set)`.
pub fn commitResidency(set: Object) void {
    resources.commitResidency(set);
}

/// Make the set available to submissions on the queue. Example: `metal.addResidencySet(queue, set)`.
pub fn addResidencySet(queue: Object, set: Object) void {
    commands.addResidencySet(queue, set);
}

/// Detach a set after consumption. Example: `metal.removeResidencySet(queue, set)`.
pub fn removeResidencySet(queue: Object, set: Object) void {
    commands.removeResidencySet(queue, set);
}

/// Owned options reused across submissions. Example: `const options = try metal.createCommitOptions();`.
pub fn createCommitOptions() !Object {
    return commands.newCommitOptions();
}

/// Owned pass that clears and stores one color target. Example: `const pass = try metal.createClearPass(texture, color);`.
pub fn createClearPass(texture: ?Object, color: ClearColor) !Object {
    const pass = try commands.newRenderPass();
    updateClearPass(pass, texture, color);
    return pass;
}

/// Reuses a pass after GPU completion. A null target releases its last texture.
pub fn updateClearPass(pass: Object, texture: ?Object, color: ClearColor) void {
    const attachment = commands.colorAttachment(pass, 0);
    commands.setTexture(attachment, texture);
    commands.setLoadAction(attachment, .clear);
    commands.setStoreAction(attachment, .store);
    commands.setClearColor(attachment, color);
}

/// Reset command memory only after previous consumption. Example: `metal.beginCommands(buffer, allocator)`.
pub fn beginCommands(buffer: Object, allocator: Object) void {
    commands.resetAllocator(allocator);
    commands.begin(buffer, allocator);
}

/// Borrowed encoder; end it before ending the command buffer. Example: `const encoder = try metal.beginRenderPass(buffer, pass);`.
pub fn beginRenderPass(buffer: Object, pass: Object) !Object {
    return commands.renderEncoder(buffer, pass) orelse error.EncoderCreationFailed;
}

/// Select the compiled pipeline. Example: `metal.setRenderPipeline(encoder, pipeline)`.
pub fn setRenderPipeline(encoder: Object, state: Object) void {
    commands.setRenderPipeline(encoder, state);
}

/// Select shader arguments for explicit stages. Example: `metal.setArgumentTable(encoder, table, .{ .vertex = true })`.
pub fn setArgumentTable(encoder: Object, table: Object, stages: RenderStages) void {
    commands.setArgumentTable(encoder, table, stages);
}

/// Encode a caller-specified instanced draw. Example: `metal.draw(encoder, .{ .vertex_count = 3 })`.
pub fn draw(encoder: Object, value: Draw) void {
    commands.draw(encoder, value);
}

/// Finish encoding the pass. Example: `metal.endRenderPass(encoder)`.
pub fn endRenderPass(encoder: Object) void {
    commands.endEncoding(encoder);
}

/// Finish commands before submission. Example: `metal.endCommands(buffer)`.
pub fn endCommands(buffer: Object) void {
    commands.end(buffer);
}

/// Submit one buffer; retain referenced resources until feedback. Example: `metal.submit(queue, buffer, options)`.
pub fn submit(queue: Object, buffer: Object, options: Object) void {
    commands.commit(queue, &.{buffer.value}, options);
}

/// Register a feedback block for the next commit; native code copies the block.
/// Example: `metal.addFeedbackHandler(options, &block)`.
pub fn addFeedbackHandler(options: Object, block: *const anyopaque) void {
    commands.addFeedbackHandler(options, block);
}

/// Borrowed NSError, valid during feedback. Example: `const failure = metal.feedbackError(feedback);`.
pub fn feedbackError(feedback: Object) ?Object {
    return commands.feedbackError(feedback);
}

/// GPU start time in seconds. Example: `const start = metal.gpuStartTime(feedback);`.
pub fn gpuStartTime(feedback: Object) f64 {
    return commands.gpuStartTime(feedback);
}

/// GPU end time in seconds. Example: `const end = metal.gpuEndTime(feedback);`.
pub fn gpuEndTime(feedback: Object) f64 {
    return commands.gpuEndTime(feedback);
}

/// Configures an existing window-owned layer before acquiring any drawables.
pub fn configureLayer(surface: Object, gpu: Object, options: LayerOptions) void {
    layer.setDevice(surface, gpu);
    layer.setPixelFormat(surface, options.format);
    resizeLayer(surface, options.size);
    layer.setFramebufferOnly(surface, options.framebuffer_only);
    layer.setDisplaySyncEnabled(surface, options.display_sync);
}

/// Set drawable dimensions in device pixels. Example: `metal.resizeLayer(surface, size)`.
pub fn resizeLayer(surface: Object, size: Size) void {
    layer.setDrawableSize(surface, .{ .width = @floatFromInt(size.width), .height = @floatFromInt(size.height) });
}

/// Borrowed drawable; acquisition may block or return null. Retain it through consumption.
/// Example: `const drawable = metal.nextDrawable(surface) orelse return error.NoDrawable;`.
pub fn nextDrawable(surface: Object) ?Object {
    return layer.nextDrawable(surface);
}

/// Borrowed render target. Example: `const texture = metal.drawableTexture(drawable);`.
pub fn drawableTexture(drawable: Object) Object {
    return layer.texture(drawable);
}

/// GPU-side wait before submitting work for the drawable. Example: `metal.waitForDrawable(queue, drawable)`.
pub fn waitForDrawable(queue: Object, drawable: Object) void {
    commands.waitForDrawable(queue, drawable);
}

/// GPU-side signal after submitting drawable work. Example: `metal.signalDrawable(queue, drawable)`.
pub fn signalDrawable(queue: Object, drawable: Object) void {
    commands.signalDrawable(queue, drawable);
}

/// Request presentation after submission and signaling. Example: `metal.present(drawable)`.
pub fn present(drawable: Object) void {
    layer.present(drawable);
}
