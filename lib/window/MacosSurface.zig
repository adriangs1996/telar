const objc = @import("objc");
const std = @import("std");
const metal = @import("metal");
const gfx = @import("gfx");
const Scene = @import("metal/Scene.zig");
const Images = @import("metal/Images.zig");
const Textures = @import("canvas/Textures.zig");
const Viewport = @import("Viewport.zig");

const c = @cImport({
    @cInclude("CoreFoundation/CFRunLoop.h");
});

const MacosSurface = @This();

const Status = enum(u8) { idle, drawing, delivered, retry, failed };
const Deadline = enum(u64) { forever = std.math.maxInt(u64) };
const Feedback = metal.GenericFeedbackBlock(struct { work: *Work });
const empty_color: metal.ClearColor = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };

// Stable storage survives moving the window during initialization. The owner
// publishes one batch; the worker finishes GPU use before publishing its result.
const Work = struct {
    layer: metal.Object,
    wake_source: c.CFRunLoopSourceRef,
    device: metal.Object,
    queue: metal.Object,
    commands: metal.Object,
    allocator: metal.Object,
    options: metal.Object,
    pass: metal.Object,
    worker: *anyopaque,
    group: *anyopaque,
    semaphore: *anyopaque,
    feedback: *Feedback.Context,
    drawable: ?metal.Object = null,
    // SAFETY: present copies the recorded clear color before publishing drawing status and dispatching the render worker.
    background: [4]f32 = undefined,
    scene: Scene,
    images: *Images,
    textures: Textures = .{},
    quads: []const gfx.Quad.Quad = &.{},
    image_draws: []const gfx.ImageDraw.ImageDraw = &.{},
    status: std.atomic.Value(Status) = .init(.idle),
    failure: ?anyerror = null,
    success: bool = false,

    fn present(self: *Work) !bool {
        const pool = metal.AutoreleasePool.init();
        defer pool.deinit();

        metal.updateClearPass(self.pass, null, empty_color);

        if (self.drawable) |*previous| {
            previous.release();
            self.drawable = null;
        }

        const borrowed = metal.nextDrawable(self.layer) orelse return false;
        const drawable = borrowed.retain();
        self.drawable = drawable;
        const color = self.background;

        metal.updateClearPass(self.pass, metal.drawableTexture(drawable), .{
            .red = color[0] * color[3],
            .green = color[1] * color[3],
            .blue = color[2] * color[3],
            .alpha = color[3],
        });

        try self.scene.prepare(self.device, self.quads, self.textures);
        metal.beginCommands(self.commands, self.allocator);

        const encoder = metal.beginRenderPass(self.commands, self.pass) catch |err| {
            metal.endCommands(self.commands);
            return err;
        };

        if (self.quads.len != 0) {
            self.scene.encode(encoder, metal.drawableTexture(drawable), self.image_draws, self.images);
        }
        metal.endRenderPass(encoder);
        metal.endCommands(self.commands);

        metal.addFeedbackHandler(self.options, self.feedback);
        metal.waitForDrawable(self.queue, drawable);
        metal.submit(self.queue, self.commands, self.options);
        metal.signalDrawable(self.queue, drawable);
        metal.present(drawable);

        // Only this worker waits. GPU feedback also orders the success write and
        // keeps command memory and the drawable alive until consumption finishes.
        _ = dispatch_semaphore_wait(self.semaphore, @intFromEnum(Deadline.forever));

        if (!self.success) {
            return error.GpuSubmissionFailed;
        }

        return true;
    }
};

const Recording = enum { idle, empty, cleared };

layer: objc.Object,
size: metal.Size,
wake_source: c.CFRunLoopSourceRef,
work: *Work,
recording: Recording = .idle,
// SAFETY: clear assigns background and marks recording cleared; present requires that state before reading the color.
background: [4]f32 = undefined,

/// Creates the canvas and all GPU resources on the window thread. Its worker
/// borrows the layer and wake source until deinit joins it; wake_pending must
/// remain valid until then. No renderer or application model is retained.
pub fn init(size: metal.Size, wake_pending: *bool) !MacosSurface {
    const class = objc.getClass("CAMetalLayer") orelse return error.ClassUnavailable;
    const raw = class.msgSend(objc.c.id, "new", .{});

    if (raw == null) {
        return error.SurfaceCreationFailed;
    }

    const layer = objc.Object.fromId(raw);
    errdefer layer.release();

    var context = std.mem.zeroes(c.CFRunLoopSourceContext);
    context.info = wake_pending;
    context.perform = wake;
    const source = c.CFRunLoopSourceCreate(null, 0, &context) orelse return error.WakeSourceFailed;
    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), source, c.kCFRunLoopCommonModes);
    errdefer {
        c.CFRunLoopRemoveSource(c.CFRunLoopGetMain(), source, c.kCFRunLoopCommonModes);
        c.CFRunLoopSourceInvalidate(source);
        c.CFRelease(source);
    }

    const work = try createWork(layer, source);

    metal.configureLayer(layer, work.device, .{
        .size = size,
        .format = .bgra8_unorm,
        .framebuffer_only = true,
        .display_sync = true,
    });

    return .{
        .layer = layer,
        .size = size,
        .wake_source = source,
        .work = work,
    };
}

/// Window-thread geometry update. Existing drawables retain their dimensions;
/// a later acquisition uses the new backing size, including display scale.
pub fn resize(self: *MacosSurface, viewport: Viewport) void {
    self.size = .{ .width = viewport.width, .height = viewport.height };
    self.layer.msgSend(void, "setContentsScale:", .{@as(f64, viewport.scale)});
    metal.resizeLayer(self.layer, self.size);
}

/// Starts recording on the window thread. An occupied canvas returns false
/// without waiting or modifying its accepted batch. A previous GPU error is
/// reported here; no application damage is retired by this operation.
pub fn begin(self: *MacosSurface) !bool {
    std.debug.assert(self.recording == .idle);
    switch (self.work.status.load(.acquire)) {
        .drawing => return false,
        .failed => return self.work.failure.?,
        .idle, .delivered, .retry => {},
    }

    metal.clearResidency(self.work.scene.residency);
    metal.commitResidency(self.work.scene.residency);
    self.work.quads = &.{};
    self.work.textures = .{};
    self.work.image_draws = &.{};
    self.recording = .empty;
    return true;
}

/// Borrows drawing inputs until takeCompletion reports that GPU use has ended.
pub fn drawQuads(self: *MacosSurface, quads: []const gfx.Quad.Quad, textures: Textures, images: []const gfx.ImageDraw.ImageDraw) void {
    std.debug.assert(self.recording != .idle);
    self.work.quads = quads;
    self.work.textures = textures;
    self.work.image_draws = images;
}

pub fn acceptImages(self: *MacosSurface, uploads: []const gfx.ImageUpload.ImageUpload, releases: []const u32) void {
    std.debug.assert(self.recording != .idle);
    self.work.images.accept(uploads, releases);
}

pub fn takeImageCompletion(self: *MacosSurface) ?gfx.ImageCompletion {
    return self.work.images.takeCompletion();
}

/// Acquire synchronizes the worker's last reads of the borrowed batch.
pub fn takeCompletion(self: *MacosSurface) !?bool {
    const status = self.work.status.load(.acquire);
    switch (status) {
        .idle, .drawing => return null,
        .failed => return self.work.failure.?,
        .delivered, .retry => {
            self.work.status.store(.idle, .release);
            return status == .delivered;
        },
    }
}

/// Records a full-canvas clear in straight-alpha RGBA. This does not submit GPU
/// work; present copies the batch before the caller can change its next frame.
pub fn clear(self: *MacosSurface, color: [4]f32) void {
    std.debug.assert(self.recording != .idle);
    self.background = color;
    self.recording = .cleared;
}

/// Submits the recorded batch asynchronously. This first slice requires clear
/// before present. Completion wakes the window; returning is not GPU completion.
pub fn present(self: *MacosSurface) void {
    std.debug.assert(self.recording == .cleared);
    self.work.background = self.background;
    self.recording = .idle;
    self.work.status.store(.drawing, .release);
    dispatch_group_enter(self.work.group);
    dispatch_async_f(self.work.worker, self.work, render);
}

/// Joins GPU work before releasing its resources, layer and wake source.
pub fn deinit(self: *MacosSurface) void {
    destroyWork(self.work);
    c.CFRunLoopRemoveSource(c.CFRunLoopGetMain(), self.wake_source, c.kCFRunLoopCommonModes);
    c.CFRunLoopSourceInvalidate(self.wake_source);
    c.CFRelease(self.wake_source);
    self.layer.release();
    self.* = undefined;
}

fn wake(context: ?*anyopaque) callconv(.c) void {
    const pending: *bool = @ptrCast(@alignCast(context.?));
    pending.* = true;
}

fn createWork(layer: metal.Object, wake_source: c.CFRunLoopSourceRef) !*Work {
    const pool = metal.AutoreleasePool.init();
    defer pool.deinit();
    const device = try metal.createDevice();
    errdefer device.release();
    const queue = try metal.createCommandQueue(device);
    errdefer queue.release();
    const commands = try metal.createCommandBuffer(device);
    errdefer commands.release();
    const allocator = try metal.createCommandAllocator(device);
    errdefer allocator.release();
    const options = try metal.createCommitOptions();
    errdefer options.release();
    const pass = try metal.createClearPass(null, empty_color);
    errdefer pass.release();
    const worker = dispatch_queue_create("telar.surface.metal", null) orelse return error.WorkerCreationFailed;
    errdefer dispatch_release(worker);
    const group = dispatch_group_create() orelse return error.WorkerCreationFailed;
    errdefer dispatch_release(group);
    const semaphore = dispatch_semaphore_create(0) orelse return error.WorkerCreationFailed;
    errdefer dispatch_release(semaphore);
    var scene = try Scene.init(device, queue);
    errdefer scene.deinit(queue);
    const images = try Images.init(device, @ptrCast(wake_source));
    errdefer images.deinit();
    const work = try std.heap.c_allocator.create(Work);
    errdefer std.heap.c_allocator.destroy(work);
    const block = Feedback.init(.{ .work = work }, &feedback);
    work.* = .{
        .layer = layer,
        .wake_source = wake_source,
        .device = device,
        .queue = queue,
        .commands = commands,
        .allocator = allocator,
        .options = options,
        .pass = pass,
        .worker = worker,
        .group = group,
        .semaphore = semaphore,
        .feedback = try Feedback.copy(&block),
        .scene = scene,
        .images = images,
    };
    return work;
}

fn destroyWork(work: *Work) void {
    _ = dispatch_group_wait(work.group, @intFromEnum(Deadline.forever));
    const pool = metal.AutoreleasePool.init();
    defer pool.deinit();
    work.scene.deinit(work.queue);
    work.images.deinit();
    Feedback.release(work.feedback);
    work.pass.release();
    if (work.drawable) |*drawable| {
        drawable.release();
    }

    work.options.release();
    work.allocator.release();
    work.commands.release();
    work.queue.release();
    work.device.release();
    dispatch_release(work.semaphore);
    dispatch_release(work.group);
    dispatch_release(work.worker);
    std.heap.c_allocator.destroy(work);
}

fn render(context: ?*anyopaque) callconv(.c) void {
    const work: *Work = @ptrCast(@alignCast(context.?));
    defer dispatch_group_leave(work.group);
    defer notify(work.wake_source);
    const delivered = work.present() catch |err| {
        work.failure = err;
        work.status.store(.failed, .release);
        return;
    };
    work.status.store(if (delivered) .delivered else .retry, .release);
}

fn feedback(block: *const Feedback.Context, raw: metal.Id) callconv(.c) void {
    const work = block.work;
    work.success = metal.feedbackError(metal.Object.fromId(raw)) == null;
    _ = dispatch_semaphore_signal(work.semaphore);
}

// C entry points supplied by macOS libdispatch, also called Grand Central
// Dispatch. The opaque pointers below are reference-counted dispatch objects.
// queue.h, group.h, semaphore.h and object.h in the SDK define these contracts.

/// createWork calls this on the window thread to create the CPU execution queue
/// stored in Work.worker. Null attributes select a serial queue, so its render
/// callbacks never overlap. libdispatch chooses the executing threads; this does
/// not create a dedicated thread or a Metal command queue. The label identifies
/// the queue in debugging tools. Work owns the returned reference and releases
/// it in destroyWork, or through createWork's errdefer if initialization fails.
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attributes: ?*anyopaque) ?*anyopaque;

/// MacosSurface.present calls this after copying the batch and entering the
/// group. It schedules render(context) on Work.worker and returns without
/// waiting. The _f variant takes a C function pointer instead of an Objective-C
/// block; libdispatch invokes render with the exact Work pointer supplied here.
/// It keeps the queue alive until the callback returns, but does not own or copy
/// Work. Our group wait prevents freeing Work while render still uses it.
extern "c" fn dispatch_async_f(queue: *anyopaque, context: ?*anyopaque, function: *const fn (?*anyopaque) callconv(.c) void) void;

/// createWork creates an initially empty counter of outstanding render jobs.
/// This group does not schedule work or track Metal automatically. present and
/// render maintain its count with enter/leave so destroyWork can wait for every
/// accepted job. Work owns the reference; initialization failure or destroyWork
/// releases it.
extern "c" fn dispatch_group_create() ?*anyopaque;

/// MacosSurface.present increments the group's outstanding-job count before
/// dispatch_async_f. Entering before enqueueing covers both queued and running
/// jobs, preventing teardown from observing an empty group while work is pending.
/// Each enter must have exactly one leave, including failed or skipped draws.
extern "c" fn dispatch_group_enter(group: *anyopaque) void;

/// render calls this through its first defer, which executes last on every exit.
/// It decrements the count after publishing delivered/retry/failed and notifying
/// the window. Reaching zero unblocks destroyWork's group wait. After this call,
/// render must not access Work or its wake source because teardown may free them.
extern "c" fn dispatch_group_leave(group: *anyopaque) void;

/// destroyWork blocks the closing window thread until the outstanding-job count
/// is zero, then frees GPU resources and dispatch objects. Deadline.forever is
/// DISPATCH_TIME_FOREVER; other deadlines are dispatch_time_t values, not a
/// duration in milliseconds. Returns zero on completion, nonzero on timeout.
/// This waits for our jobs, not directly for the GPU: Work.present waits for GPU
/// feedback before render leaves the group. Waiting from render itself would
/// deadlock, since its own leave could never run.
extern "c" fn dispatch_group_wait(group: *anyopaque, deadline: u64) isize;

/// createWork creates the counting semaphore with value zero, so a GPU signal
/// is required before Work.present can finish waiting. It is reused for each
/// admitted submission, with one feedback signal consumed by one worker wait.
/// A signal arriving before the wait remains available. Returns an owned
/// reference, or null on failure; createWork and destroyWork handle its release.
extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;

/// feedback calls this from Metal's completion callback after writing
/// Work.success. It adds one permit and wakes the waiting worker if necessary;
/// the matching wait synchronizes the worker's read of success. Returns nonzero
/// when a thread was woken, otherwise zero. That return value is not the GPU
/// result, so feedback ignores it. This does not itself wake the window loop.
extern "c" fn dispatch_semaphore_signal(semaphore: *anyopaque) isize;

/// Work.present consumes the feedback permit after submitting and requesting
/// presentation. If feedback has not signaled yet, only the dispatch worker
/// blocks, leaving the window thread available for events. The forever deadline
/// disables timeout. Zero means a permit was consumed; nonzero means timeout.
/// Once it returns, Work.present can read success and finish GPU resource use
/// for this batch. Feedback completion does not prove the frame reached scanout.
extern "c" fn dispatch_semaphore_wait(semaphore: *anyopaque, deadline: u64) isize;

/// Releases an owned reference to a queue, group or semaphore. createWork uses
/// it in errdefer before any jobs exist; destroyWork uses it after the group wait
/// has finished. Dispatch objects are reference-counted, so this is not free(),
/// a cancellation request or a join. Jobs and semaphore waits must already be
/// finished before we release the references that protect their resources.
extern "c" fn dispatch_release(object: *anyopaque) void;

// Worker threads signal a source; only its main-run-loop callback writes the
// window's pending flag. Teardown joins the worker before invalidating it.
fn notify(source: c.CFRunLoopSourceRef) void {
    c.CFRunLoopSourceSignal(source);
    c.CFRunLoopWakeUp(c.CFRunLoopGetMain());
}
