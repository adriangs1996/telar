const core = @import("telar-core");
const State = @import("State.zig");
const Pipeline = @import("Pipeline.zig");
const PaneMediaAllocator = @import("PaneMediaAllocator.zig");
const GraphicsLimits = @import("GraphicsLimits.zig");
const std = @import("std");
const Responses = @import("Responses.zig");
const Stats = @import("Stats.zig");
const SharedFrameView = @import("SharedFrameView.zig");
const FileQueryView = @import("FileQueryView.zig");
const LiveImages = @import("LiveImages.zig");
const shared_transfer = @import("shared_transfer.zig");
const PreparedTransfer = @import("PreparedTransfer.zig");
const GraphicsIngest = @import("GraphicsIngest.zig");
const Processor = @This();

state: *State,
media: *Pipeline,
media_allocator: *PaneMediaAllocator,
graphics_limits: GraphicsLimits,
graphics_storage_limit: usize,
io: std.Io,
responses: Responses,

pub fn processMedia(self: *Processor, current_size: core.TerminalSize, stats: *Stats) void {
    if (self.media.sealedRequiresReset()) {
        self.state.kitty_framing = .{};
        self.state.kitty_loading_chunks = 0;
        self.state.prepared_transfers.discardAll(self.media_allocator);
        self.state.transfer_preparation.deinit(self.media_allocator);
    }

    const Sink = struct {
        processor: *Processor,

        pub fn observe(sink: *@This(), bytes: []const u8) void {
            sink.processor.ingestMediaOutput(bytes);
        }

        pub fn observeSharedFrame(sink: *@This(), frame: SharedFrameView) bool {
            return sink.processor.ingestSharedFrame(frame);
        }

        pub fn observeFileQuery(sink: *@This(), query: FileQueryView) bool {
            return sink.processor.answerFileQuery(query);
        }
    };
    var sink: Sink = .{ .processor = self };
    self.media.processSealed(.{ .current_size = current_size, .stats = stats }, &sink);
    if (!stats.failed and self.state.shared_transport_clients.load(.acquire) != 0) {
        self.prepareSharedTransfers(stats);
    }

    self.state.transfer_preparation.process(&self.media.terminal.screens.active.kitty_images, self.media_allocator);
}

/// Freezes every generation the emulator holds that no local client has
/// been offered yet, on the media actor with the pixels still hot. A
/// frame that cannot be frozen here is left to the runtime thread's
/// fallback copy, so nothing is lost, only deferred.
///
/// ```zig
/// processor.prepareSharedTransfers(&stats);
/// ```
pub fn prepareSharedTransfers(self: *Processor, stats: *Stats) void {
    const storage = &self.media.terminal.screens.active.kitty_images;
    self.state.prepared_transfers.retain(LiveImages{ .storage = storage }, self.media_allocator);
    var images = storage.images.iterator();
    while (images.next()) |entry| {
        const image = entry.value_ptr;
        const pixels = self.media_allocator.imagePixels(image.data.bytes()) orelse continue;
        const image_key: core.ImageKey = .{ .image_id = image.id, .generation = image.generation };
        if (self.state.prepared_transfers.covers(image_key)) {
            continue;
        }
        const format: core.Format = switch (image.format) {
            .rgb => .rgb,
            .rgba => .rgba,
            else => continue,
        };
        const metadata: core.Image = .{
            .key = image_key,
            .format = format,
            .width = image.width,
            .height = image.height,
            .byte_len = pixels.len,
        };
        _ = metadata.validate(self.graphics_storage_limit) catch continue;
        if (!self.media_allocator.reserveManual(pixels.len)) {
            continue;
        }
        const name = shared_transfer.freezeSharedPixels(pixels) orelse {
            self.media_allocator.releaseManual(pixels.len);
            continue;
        };
        const transfer: PreparedTransfer = .{
            .metadata = metadata,
            .name = name,
            .reserved_len = pixels.len,
        };
        if (!self.state.prepared_transfers.put(transfer, self.media_allocator)) {
            _ = std.c.shm_unlink(name.sliceZ());
            self.media_allocator.releaseManual(pixels.len);
            continue;
        }
        stats.prepared_frames +|= 1;
    }
}

/// Loads one complete shared-memory frame with a single copy: the child's
/// object is copied straight into a fresh runtime-owned object whose
/// read-only mapping becomes the emulator's image storage and, for local
/// clients, the parked transfer. The emulator still sees the envelope and
/// a synthesized placement, so cursor policy and synchronized output
/// behave as if it had parsed the frame. Returns false to let the
/// emulator parse the frame the ordinary way.
///
/// ```zig
/// if (!processor.ingestSharedFrame(frame)) processor.ingestMediaOutput(frame.bytes);
/// ```
fn ingestSharedFrame(self: *Processor, frame: SharedFrameView) bool {
    if (comptime !shared_transfer.shared_memory_supported) {
        return false;
    }
    if (frame.byte_len > self.graphics_storage_limit) {
        return false;
    }
    // The emulator stamps the generation on store; validate everything
    // else now with a placeholder that passes the identity check.
    const metadata: core.Image = .{
        .key = .{ .image_id = frame.image_id, .generation = 1 },
        .format = frame.format,
        .width = frame.width,
        .height = frame.height,
        .byte_len = frame.byte_len,
    };
    _ = metadata.validate(self.graphics_storage_limit) catch return false;

    const child = switch (frame.medium) {
        .shared => shared_transfer.mapChildObject(frame.encoded_name, frame.byte_len),
        .file => shared_transfer.mapChildFile(frame.encoded_name, frame.byte_len),
    } orelse return false;
    defer child.close();
    const media = self.media_allocator.allocator();
    const placeholder = media.alloc(u8, 1) catch return false;
    if (!self.media_allocator.reserveManual(frame.byte_len)) {
        media.free(placeholder);
        return false;
    }
    const name = shared_transfer.freezeSharedPixels(child.pixels) orelse {
        self.media_allocator.releaseManual(frame.byte_len);
        media.free(placeholder);
        return false;
    };
    const storage = shared_transfer.mapOwnObject(name, frame.byte_len) orelse {
        _ = std.c.shm_unlink(name.sliceZ());
        self.media_allocator.releaseManual(frame.byte_len);
        media.free(placeholder);
        return false;
    };
    if (!self.media_allocator.adoptMapping(placeholder, storage)) {
        std.posix.munmap(storage);
        _ = std.c.shm_unlink(name.sliceZ());
        self.media_allocator.releaseManual(frame.byte_len);
        media.free(placeholder);
        return false;
    }

    self.ingestMediaOutput(frame.bytes[0..frame.apc_start]);
    const images = &self.media.terminal.screens.active.kitty_images;
    images.addImage(self.io, media, self.media.terminal.screens.active, .{
        .id = frame.image_id,
        .width = frame.width,
        .height = frame.height,
        .format = switch (frame.format) {
            .rgb => .rgb,
            .rgba => .rgba,
        },
        .data = .{ .complete = placeholder },
    }) catch {
        // Freeing the placeholder unmaps the object and releases the
        // reservation exactly once.
        media.free(placeholder);
        _ = std.c.shm_unlink(name.sliceZ());
        self.ingestMediaOutput(frame.bytes[frame.apc_end..]);
        return true;
    };
    var placement: [64]u8 = undefined;
    const command = std.fmt.bufPrint(
        &placement,
        "\x1b_Ga=p,i={d},p={d},C=1,q=2\x1b\\",
        .{ frame.image_id, frame.placement_id },
    ) catch unreachable;
    self.ingestMediaOutput(command);
    self.ingestMediaOutput(frame.bytes[frame.apc_end..]);

    const generation = images.imageById(frame.image_id).?.generation;
    var parked = metadata;
    parked.key.generation = generation;
    const transfer: PreparedTransfer = .{
        .metadata = parked,
        .name = name,
        // The mapping's reservation belongs to emulator storage; the
        // parked name adds no bytes of its own.
        .reserved_len = 0,
    };
    if (self.state.shared_transport_clients.load(.acquire) == 0 or
        !self.state.prepared_transfers.put(transfer, self.media_allocator))
    {
        _ = std.c.shm_unlink(name.sliceZ());
    }
    return true;
}

/// Answers a child's `a=q,t=f` capability query on the emulator's behalf:
/// `OK` when the named file passes the same validation a frame would,
/// `EBADF` otherwise. The reply joins the bounded PTY response queue.
///
/// ```zig
/// _ = processor.answerFileQuery(query);
/// ```
fn answerFileQuery(self: *Processor, query: FileQueryView) bool {
    var reply: [64]u8 = undefined;
    const accepted = query.byte_len <= self.graphics_storage_limit and
        shared_transfer.validateChildFile(query.encoded_path, query.byte_len);
    const bytes = std.fmt.bufPrint(&reply, "\x1b_Gi={d};{s}\x1b\\", .{
        query.image_id,
        if (accepted) "OK" else "EBADF:file not accepted",
    }) catch unreachable;
    self.responses.write(bytes);
    return true;
}

fn ingestMediaOutput(self: *Processor, bytes: []const u8) void {
    const loading_id = if (self.media.terminal.screens.active.kitty_images.loading) |loading|
        loading.image.id
    else
        null;
    const kitty_commands = self.state.kitty_framing.observe(bytes);
    self.media.stream.nextSlice(bytes);
    self.enforceIncompleteGraphics(.{
        .io = self.io,
        .previous_loading_id = loading_id,
        .completed_commands = kitty_commands,
    });
}

fn enforceIncompleteGraphics(self: *Processor, observation: GraphicsIngest) void {
    const io = observation.io;
    const previous_loading_id = observation.previous_loading_id;
    const completed_commands = observation.completed_commands;

    const storage = &self.media.terminal.screens.active.kitty_images;
    if (previous_loading_id != null or storage.loading != null) {
        self.state.kitty_loading_chunks +|= completed_commands;
    } else {
        self.state.kitty_loading_chunks = 0;
    }

    const chunk_limit_exceeded = self.state.kitty_loading_chunks > self.graphics_limits.chunks_per_image;
    const loading = storage.loading orelse {
        if (chunk_limit_exceeded) {
            if (previous_loading_id) |image_id| {
                storage.delete(io, self.media_allocator.allocator(), &self.media.terminal, .{ .id = .{
                    .delete = true,
                    .image_id = image_id,
                } });
                self.queueGraphicsLimitResponse(image_id);
            }
        }
        self.state.kitty_loading_chunks = 0;
        return;
    };
    if (!chunk_limit_exceeded and
        loading.data.items.len <= self.graphics_storage_limit)
    {
        return;
    }

    const image_id = loading.image.id;
    loading.destroy(self.media_allocator.allocator());
    storage.loading = null;
    self.state.kitty_loading_chunks = 0;
    self.queueGraphicsLimitResponse(image_id);
}

pub fn queueGraphicsLimitResponse(self: *Processor, image_id: u32) void {
    var response: [128]u8 = undefined;
    const bytes = std.fmt.bufPrint(
        &response,
        "\x1b_Gi={d};ENOMEM: graphics upload limit exceeded\x1b\\",
        .{image_id},
    ) catch return;
    self.responses.write(bytes);
}
