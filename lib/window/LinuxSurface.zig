const gfx = @import("gfx");
const Textures = @import("canvas/Textures.zig");
const std = @import("std");
const wayland = @import("wayland.zig");
const c = wayland.c;
const LinuxSurface = @This();

const Status = enum(u8) { idle, drawing, delivered, retry, failed };
const Recording = enum { idle, empty, cleared };
const Deadline = enum(u64) { forever = std.math.maxInt(u64) };

const Work = struct {
    gpu: c.telar_vulkan_device = std.mem.zeroes(c.telar_vulkan_device),
    swapchain: c.telar_vulkan_swapchain = std.mem.zeroes(c.telar_vulkan_swapchain),
    pool: c.VkCommandPool = null,
    commands: c.VkCommandBuffer = null,
    fence: c.VkFence = null,
    available: c.VkSemaphore = null,
    // SAFETY: sem_init succeeds before the worker is spawned; job_ready guards destruction during partial initialization.
    job: c.sem_t = undefined,
    job_ready: bool = false,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    status: std.atomic.Value(Status) = .init(.idle),
    failure: ?anyerror = null,
    completion_fd: c_int,
    // SAFETY: present copies the clear color before publishing drawing status and posting the worker semaphore.
    background: [4]f32 = undefined,
    batch: c.telar_gui_frame = std.mem.zeroes(c.telar_gui_frame),
    pipeline: c.telar_vulkan_pipeline = std.mem.zeroes(c.telar_vulkan_pipeline),
    resources: ?*c.telar_vulkan_resources = null,
    images: ?*c.telar_vulkan_images = null,
    // SAFETY: present copies the surface extent before posting work; the worker reads it only for an admitted drawing job.
    size: c.VkExtent2D = undefined,

    fn run(self: *Work) void {
        while (true) {
            while (c.sem_wait(&self.job) != 0) {
                if (c.__errno_location().* != c.EINTR) {
                    self.failure = error.WorkerWaitFailed;
                    self.status.store(.failed, .release);
                    notify(self.completion_fd);
                    return;
                }
            }

            if (self.stopping.load(.acquire)) {
                return;
            }

            const delivered = self.paint() catch |err| {
                self.failure = err;
                self.status.store(.failed, .release);
                notify(self.completion_fd);
                continue;
            };

            self.status.store(
                if (delivered) .delivered else .retry,
                .release,
            );

            notify(self.completion_fd);
        }
    }

    fn paint(self: *Work) !bool {
        if (!c.telar_vulkan_swapchain_resize(&self.swapchain, self.size)) {
            return error.SwapchainCreationFailed;
        }

        if (self.pipeline.pipeline == null or self.pipeline.format != self.swapchain.format) {
            c.telar_vulkan_resources_destroy(self.resources);
            self.resources = null;
            c.telar_vulkan_pipeline_deinit(&self.pipeline);
            if (!c.telar_vulkan_pipeline_init(&self.pipeline, self.gpu.device, self.swapchain.format, c.telar_vulkan_images_layout(self.images))) {
                return error.PipelineCreationFailed;
            }

            self.resources = c.telar_vulkan_resources_create(&self.gpu, &self.pipeline) orelse return error.ResourceCreationFailed;
        }

        // SAFETY: Swapchain acquisition writes index on success or suboptimal success; all other results return before encode reads it.
        var index: u32 = undefined;
        const acquired = c.telar_vulkan_swapchain_acquire(&self.swapchain, self.available, &index);

        switch (acquired) {
            c.VK_ERROR_OUT_OF_DATE_KHR, c.VK_TIMEOUT, c.VK_NOT_READY => return false,
            c.VK_SUCCESS, c.VK_SUBOPTIMAL_KHR => {},
            else => return error.DrawableAcquisitionFailed,
        }

        self.encode(index) catch |err| {
            // Acquisition already signaled a semaphore. Consume it even if no
            // drawing commands can be submitted, before teardown destroys it.
            try self.submit(index, false);
            try check(c.vkWaitForFences(
                self.gpu.device,
                1,
                &self.fence,
                c.VK_TRUE,
                @intFromEnum(Deadline.forever),
            ));
            return err;
        };

        self.submit(index, true) catch |err| {
            try self.submit(index, false);

            try check(c.vkWaitForFences(
                self.gpu.device,
                1,
                &self.fence,
                c.VK_TRUE,
                @intFromEnum(Deadline.forever),
            ));

            return err;
        };

        const presented = c.telar_vulkan_swapchain_present(&self.swapchain, index);
        try check(c.vkWaitForFences(self.gpu.device, 1, &self.fence, c.VK_TRUE, @intFromEnum(Deadline.forever)));

        return switch (presented) {
            c.VK_SUCCESS, c.VK_SUBOPTIMAL_KHR => true,
            c.VK_ERROR_OUT_OF_DATE_KHR => false,
            else => error.PresentationFailed,
        };
    }

    fn encode(self: *Work, index: u32) !void {
        try check(c.vkResetCommandBuffer(self.commands, 0));

        const begin_commands = std.mem.zeroInit(c.VkCommandBufferBeginInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        });

        try check(c.vkBeginCommandBuffer(self.commands, &begin_commands));
        if (!c.telar_vulkan_resources_prepare(self.resources, self.commands, &self.batch)) {
            return error.ResourceUploadFailed;
        }

        const target = self.swapchain.targets[index];
        self.barrier(target.image, false);
        const alpha: f32 = if (self.swapchain.transparent) self.background[3] else 1;

        const attachment = std.mem.zeroInit(c.VkRenderingAttachmentInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = target.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = c.VkClearValue{
                .color = .{
                    .float32 = .{
                        self.background[0] * alpha,
                        self.background[1] * alpha,
                        self.background[2] * alpha,
                        alpha,
                    },
                },
            },
        });

        const rendering = std.mem.zeroInit(c.VkRenderingInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain.extent },
            .layerCount = 1,
            .colorAttachmentCount = 1,
            .pColorAttachments = &attachment,
        });

        c.vkCmdBeginRendering(self.commands, &rendering);
        self.drawQuads();
        c.vkCmdEndRendering(self.commands);
        self.barrier(target.image, true);
        try check(c.vkEndCommandBuffer(self.commands));
    }

    fn drawQuads(self: *Work) void {
        if (self.batch.quad_count == 0) {
            return;
        }

        const size = [2]f32{ @floatFromInt(self.swapchain.extent.width), @floatFromInt(self.swapchain.extent.height) };
        const viewport: c.VkViewport = .{ .x = 0, .y = 0, .width = size[0], .height = size[1], .minDepth = 0, .maxDepth = 1 };
        const scissor: c.VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain.extent };
        c.vkCmdBindPipeline(self.commands, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.pipeline);
        c.vkCmdSetViewport(self.commands, 0, 1, &viewport);
        c.vkCmdSetScissor(self.commands, 0, 1, &scissor);
        c.vkCmdBindDescriptorSets(self.commands, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.layout, 0, 1, &self.pipeline.descriptors, 0, null);
        c.vkCmdPushConstants(self.commands, self.pipeline.layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(@TypeOf(size)), &size);
        self.bindImage(c.telar_vulkan_images_fallback(self.images));
        var next: u32 = 0;
        for (0..self.batch.image_draw_count) |index| {
            const draw = self.batch.image_draws[index];
            if (draw.quad < next or draw.quad >= self.batch.quad_count) {
                continue;
            }

            self.drawRange(next, draw.quad);
            next = draw.quad + 1;
            const image = c.telar_vulkan_images_set(self.images, draw.handle);
            if (image == null) {
                continue;
            }

            self.bindImage(image);
            self.drawRange(draw.quad, next);
        }

        self.drawRange(next, self.batch.quad_count);
    }

    fn bindImage(self: *Work, set: c.VkDescriptorSet) void {
        c.vkCmdBindDescriptorSets(self.commands, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.layout, 1, 1, &set, 0, null);
    }

    fn drawRange(self: *Work, first: u32, end: u32) void {
        const Vertices = enum(u32) { rectangle = 6 };
        if (first < end) {
            c.vkCmdDraw(self.commands, @intFromEnum(Vertices.rectangle), end - first, 0, first);
        }
    }

    fn barrier(self: *Work, image: c.VkImage, presenting: bool) void {
        const image_barrier = std.mem.zeroInit(c.VkImageMemoryBarrier2, .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .srcStageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = if (presenting) c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT else 0,
            .dstStageMask = if (presenting) c.VK_PIPELINE_STAGE_2_NONE else c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstAccessMask = if (presenting) 0 else c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = if (presenting) @as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL) else @as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_UNDEFINED),
            .newLayout = if (presenting) @as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR) else @as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL),
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = c.VkImageSubresourceRange{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        });

        const dependency = std.mem.zeroInit(c.VkDependencyInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &image_barrier,
        });

        c.vkCmdPipelineBarrier2(self.commands, &dependency);
    }

    fn submit(self: *Work, index: u32, draw: bool) !void {
        const wait = std.mem.zeroInit(c.VkSemaphoreSubmitInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = self.available,
            .stageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        });

        const signal = std.mem.zeroInit(c.VkSemaphoreSubmitInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = self.swapchain.targets[index].finished,
            .stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        });

        const commands = std.mem.zeroInit(c.VkCommandBufferSubmitInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .commandBuffer = self.commands,
        });

        const submission = std.mem.zeroInit(c.VkSubmitInfo2, .{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .waitSemaphoreInfoCount = 1,
            .pWaitSemaphoreInfos = &wait,
            .commandBufferInfoCount = if (draw) @as(u32, 1) else @as(u32, 0),
            .pCommandBufferInfos = &commands,
            .signalSemaphoreInfoCount = if (draw) @as(u32, 1) else @as(u32, 0),
            .pSignalSemaphoreInfos = &signal,
        });

        try check(c.vkResetFences(self.gpu.device, 1, &self.fence));
        _ = c.pthread_mutex_lock(&self.gpu.queue_lock);
        defer _ = c.pthread_mutex_unlock(&self.gpu.queue_lock);
        try check(c.vkQueueSubmit2(self.gpu.queue, 1, &submission, self.fence));
    }
};

/// Borrowed connection; the window disconnects after destroying this surface.
display: *c.wl_display,
handle: *c.wl_surface,
/// The window event loop polls this alongside its display and runtime wake fd.
completion_fd: c_int,
work: ?*Work,
size: c.VkExtent2D = .{ .width = 0, .height = 0 },
configured: bool = false,
recording: Recording = .idle,
// SAFETY: clear assigns background before marking recording cleared; present requires a cleared recording before reading it.
background: [4]f32 = undefined,
// SAFETY: imageCompleted assigns each completion before increasing image_completion_count; consumers read only queued completions.
image_completions: [gfx.ImageUpload.uploads_in_flight]gfx.ImageCompletion = undefined,
image_completion_count: usize = 0,

/// Initializes Vulkan and one sleeping worker. The window must acknowledge the
/// initial xdg configure before enabling drawing through configure(). No frame
/// or application state is retained by the canvas.
pub fn init(display: *c.wl_display, compositor: *c.wl_compositor) !LinuxSurface {
    const handle = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreationFailed;
    errdefer c.wl_surface_destroy(handle);
    const completion_fd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
    if (completion_fd < 0) {
        return error.WakeSourceFailed;
    }

    errdefer _ = c.close(completion_fd);
    return .{
        .display = display,
        .handle = handle,
        .completion_fd = completion_fd,
        .work = try createWork(display, handle, completion_fd),
    };
}

/// Called by the window after ack_configure. Copy geometry into a future batch;
/// never mutate dimensions the worker is currently reading.
pub fn configure(self: *LinuxSurface, width: u32, height: u32) void {
    self.size = .{ .width = width, .height = height };
    self.configured = true;
}

/// Matches the macOS canvas: an occupied or unconfigured destination defers
/// drawing without waiting. The next admitted batch uses the latest geometry.
pub fn begin(self: *LinuxSurface) !bool {
    std.debug.assert(self.recording == .idle);
    const work = self.work orelse return false;
    drain(self.completion_fd);
    switch (work.status.load(.acquire)) {
        .drawing => return false,
        .failed => return work.failure.?,
        .idle, .delivered, .retry => {},
    }

    if (!self.configured or self.size.width == 0 or self.size.height == 0) {
        return false;
    }

    work.batch = std.mem.zeroes(c.telar_gui_frame);
    self.recording = .empty;
    return true;
}

/// Records borrowed drawing inputs. They remain sealed until takeCompletion.
pub fn drawQuads(self: *LinuxSurface, quads: []const gfx.Quad.Quad, textures: Textures, images: []const gfx.ImageDraw.ImageDraw) void {
    std.debug.assert(self.recording != .idle);
    const batch = &self.work.?.batch;
    batch.quads = @ptrCast(quads.ptr);
    batch.quad_count = @intCast(quads.len);
    batch.atlas = textures.atlas;
    batch.atlas_side = textures.atlas_side;
    batch.atlas_version = textures.atlas_version;
    batch.atlas_dirty_base = textures.atlas_dirty_base;
    batch.atlas_dirty_top = textures.atlas_dirty_top;
    batch.atlas_dirty_bottom = textures.atlas_dirty_bottom;
    batch.sprites = textures.sprites;
    batch.sprites_side = textures.sprites_side;
    batch.sprites_version = textures.sprites_version;
    @memcpy(std.mem.asBytes(&batch.diagrams), std.mem.asBytes(&textures.diagrams));
    batch.image_draws = @ptrCast(images.ptr);
    batch.image_draw_count = @intCast(images.len);
}

pub fn acceptImages(self: *LinuxSurface, uploads: []const gfx.ImageUpload.ImageUpload, releases: []const u32) void {
    std.debug.assert(self.recording != .idle);
    var batch = std.mem.zeroes(c.telar_gui_frame);
    batch.image_uploads = @ptrCast(uploads.ptr);
    batch.image_upload_count = @intCast(uploads.len);
    batch.image_releases = releases.ptr;
    batch.image_release_count = @intCast(releases.len);
    c.telar_vulkan_images_accept(self.work.?.images, &batch);
}

pub fn imagesFd(self: *LinuxSurface) c_int {
    return if (self.work) |work| c.telar_vulkan_images_fd(work.images) else -1;
}

pub fn takeImageCompletion(self: *LinuxSurface) ?gfx.ImageCompletion {
    if (self.image_completion_count == 0) {
        const work = self.work orelse return null;
        c.telar_vulkan_images_take(work.images, imageCompleted, self);
    }

    if (self.image_completion_count == 0) {
        return null;
    }

    self.image_completion_count -= 1;
    return self.image_completions[self.image_completion_count];
}

// The C upload queue invokes this synchronously while takeImageCompletion drains
// its bounded results. Only the surface is retained, never an application owner.
fn imageCompleted(context: ?*anyopaque, handle: u32, success: c_int) callconv(.c) void {
    const self: *LinuxSurface = @ptrCast(@alignCast(context.?));
    std.debug.assert(self.image_completion_count < self.image_completions.len);
    self.image_completions[self.image_completion_count] = .{ .handle = handle, .success = success != 0 };
    self.image_completion_count += 1;
}

pub fn takeCompletion(self: *LinuxSurface) !?bool {
    const work = self.work orelse return null;
    const status = work.status.load(.acquire);
    switch (status) {
        .idle, .drawing => return null,
        .failed => return work.failure.?,
        .delivered, .retry => {
            work.status.store(.idle, .release);
            return status == .delivered;
        },
    }
}

pub fn clear(self: *LinuxSurface, color: [4]f32) void {
    std.debug.assert(self.recording != .idle);
    self.background = color;
    self.recording = .cleared;
}

/// Copies and submits one batch. GPU waits and swapchain rebuilds happen on the
/// worker, which signals completion_fd after publishing success, retry or error.
pub fn present(self: *LinuxSurface) void {
    std.debug.assert(self.recording == .cleared);
    const work = self.work.?;
    work.background = self.background;
    work.batch.background = self.background;
    work.size = self.size;
    self.recording = .idle;
    work.status.store(.drawing, .release);
    _ = c.sem_post(&work.job);
}

/// Stop before destroying xdg roles: an accepted batch may still commit a buffer
/// through Wayland. Idempotent so partial window initialization can unwind safely.
pub fn stop(self: *LinuxSurface) void {
    if (self.work) |work| {
        destroyWork(work);
        self.work = null;
    }
}

pub fn deinit(self: *LinuxSurface) void {
    self.stop();
    _ = c.close(self.completion_fd);
    c.wl_surface_destroy(self.handle);
    self.* = undefined;
}

fn createWork(display: *c.wl_display, handle: *c.wl_surface, completion_fd: c_int) !*Work {
    const work = try std.heap.c_allocator.create(Work);
    work.* = .{ .completion_fd = completion_fd };
    work.swapchain.gpu = &work.gpu;
    errdefer destroyWork(work);
    if (!c.telar_vulkan_device_init(&work.gpu, display, handle)) {
        return error.VulkanInitializationFailed;
    }

    const pool = std.mem.zeroInit(c.VkCommandPoolCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = work.gpu.queue_family,
    });
    try check(c.vkCreateCommandPool(work.gpu.device, &pool, null, &work.pool));
    const commands = std.mem.zeroInit(c.VkCommandBufferAllocateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = work.pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    });
    try check(c.vkAllocateCommandBuffers(work.gpu.device, &commands, &work.commands));
    const fence = std.mem.zeroInit(c.VkFenceCreateInfo, .{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO });
    try check(c.vkCreateFence(work.gpu.device, &fence, null, &work.fence));
    const semaphore = std.mem.zeroInit(c.VkSemaphoreCreateInfo, .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO });
    try check(c.vkCreateSemaphore(work.gpu.device, &semaphore, null, &work.available));
    if (c.sem_init(&work.job, 0, 0) != 0) {
        return error.WorkerCreationFailed;
    }

    work.job_ready = true;
    work.images = c.telar_vulkan_images_create(&work.gpu) orelse return error.ImageWorkerCreationFailed;
    work.thread = try std.Thread.spawn(.{}, Work.run, .{work});
    return work;
}

fn destroyWork(work: *Work) void {
    if (work.thread) |thread| {
        work.stopping.store(true, .release);
        _ = c.sem_post(&work.job);
        thread.join();
    }

    if (work.job_ready) {
        _ = c.sem_destroy(&work.job);
    }

    c.telar_vulkan_images_destroy(work.images);
    if (work.gpu.device != null) {
        _ = c.vkDeviceWaitIdle(work.gpu.device);
        c.telar_vulkan_swapchain_deinit(&work.swapchain);
        c.telar_vulkan_resources_destroy(work.resources);
        c.telar_vulkan_pipeline_deinit(&work.pipeline);
        if (work.available != null) {
            c.vkDestroySemaphore(work.gpu.device, work.available, null);
        }

        if (work.fence != null) {
            c.vkDestroyFence(work.gpu.device, work.fence, null);
        }

        if (work.pool != null) {
            c.vkDestroyCommandPool(work.gpu.device, work.pool, null);
        }
    }

    c.telar_vulkan_device_deinit(&work.gpu);
    std.heap.c_allocator.destroy(work);
}

fn check(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) {
        return error.VulkanOperationFailed;
    }
}

fn notify(fd: c_int) void {
    while (c.eventfd_write(fd, 1) != 0 and c.__errno_location().* == c.EINTR) {}
}

fn drain(fd: c_int) void {
    // SAFETY: eventfd_read receives value only as output storage; the drained counter is never inspected.
    var value: c.eventfd_t = undefined;
    while (c.eventfd_read(fd, &value) != 0 and c.__errno_location().* == c.EINTR) {}
}
