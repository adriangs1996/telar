const Processor = @This();
const State = @import("State.zig");
const media_mod = @import("root.zig");
const allocation = @import("allocator.zig");
const source_namespace = @import("ingestion.zig");
const Responses = @import("Responses.zig");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const shared_transfer = @import("shared_transfer.zig");
const std = @import("std");
state: *State,
media: *media_mod.Pipeline,
media_allocator: *allocation.PaneMediaAllocator,
graphics_limits: allocation.GraphicsLimits,
graphics_storage_limit: usize,
io: source_namespace.Io,
responses: Responses,
const GraphicsIngest = struct {
    io: source_namespace.Io,
    previous_loading_id: ?u32,
    completed_commands: usize,
};

pub fn processMedia(processor: *Processor, current_size: source_namespace.schema.TerminalSize, stats: *media_mod.Stats) void {
    if (processor.media.sealedRequiresReset()) {
        processor.state.kitty_framing = .{};
        processor.state.kitty_loading_chunks = 0;
        processor.state.prepared_transfers.discardAll(processor.media_allocator);
        processor.state.transfer_preparation.deinit(processor.media_allocator);
    }

    const Sink = struct {
        processor: *Processor,

        pub fn observe(sink: *@This(), bytes: []const u8) void {
            sink.processor.ingestMediaOutput(bytes);
        }

        pub fn observeSharedFrame(sink: *@This(), frame: media_mod.SharedFrameView) bool {
            return sink.processor.ingestSharedFrame(frame);
        }

        pub fn observeFileQuery(sink: *@This(), query: media_mod.FileQueryView) bool {
            return sink.processor.answerFileQuery(query);
        }
    };
    var sink: Sink = .{ .processor = processor };
    processor.media.processSealed(.{ .current_size = current_size, .stats = stats }, &sink);
    if (!stats.failed and processor.state.shared_transport_clients.load(.acquire) != 0) {
        processor.prepareSharedTransfers(stats);
    }

    processor.state.transfer_preparation.process(&processor.media.terminal.screens.active.kitty_images, processor.media_allocator);
}

const LiveImages = struct {
    storage: *const vt.kitty.graphics.ImageStorage,

    pub fn holds(alive: LiveImages, image_key: core.graphics.ImageKey) bool {
        const image = alive.storage.imageById(image_key.image_id) orelse return false;
        return image.generation == image_key.generation;
    }

    pub fn holdsImage(alive: LiveImages, image_id: u32) bool {
        return alive.storage.imageById(image_id) != null;
    }
};

/// Freezes every generation the emulator holds that no local client has
/// been offered yet, on the media actor with the pixels still hot. A
/// frame that cannot be frozen here is left to the runtime thread's
/// fallback copy, so nothing is lost, only deferred.
///
/// ```zig
/// processor.prepareSharedTransfers(&stats);
/// ```
pub fn prepareSharedTransfers(processor: *Processor, stats: *media_mod.Stats) void {
    const storage = &processor.media.terminal.screens.active.kitty_images;
    processor.state.prepared_transfers.retain(LiveImages{ .storage = storage }, processor.media_allocator);
    var images = storage.images.iterator();
    while (images.next()) |entry| {
        const image = entry.value_ptr;
        const pixels = processor.media_allocator.imagePixels(image.data.bytes()) orelse continue;
        const image_key: core.graphics.ImageKey = .{ .image_id = image.id, .generation = image.generation };
        if (processor.state.prepared_transfers.covers(image_key)) {
            continue;
        }
        const format: core.graphics.Format = switch (image.format) {
            .rgb => .rgb,
            .rgba => .rgba,
            else => continue,
        };
        const metadata: core.graphics.Image = .{
            .key = image_key,
            .format = format,
            .width = image.width,
            .height = image.height,
            .byte_len = pixels.len,
        };
        _ = metadata.validate(processor.graphics_storage_limit) catch continue;
        if (!processor.media_allocator.reserveManual(pixels.len)) {
            continue;
        }
        const name = shared_transfer.freezeSharedPixels(pixels) orelse {
            processor.media_allocator.releaseManual(pixels.len);
            continue;
        };
        const transfer: shared_transfer.PreparedTransfer = .{
            .metadata = metadata,
            .name = name,
            .reserved_len = pixels.len,
        };
        if (!processor.state.prepared_transfers.put(transfer, processor.media_allocator)) {
            _ = std.c.shm_unlink(name.sliceZ());
            processor.media_allocator.releaseManual(pixels.len);
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
fn ingestSharedFrame(processor: *Processor, frame: media_mod.SharedFrameView) bool {
    if (comptime !shared_transfer.shared_memory_supported) {
        return false;
    }
    if (frame.byte_len > processor.graphics_storage_limit) {
        return false;
    }
    // The emulator stamps the generation on store; validate everything
    // else now with a placeholder that passes the identity check.
    const metadata: core.graphics.Image = .{
        .key = .{ .image_id = frame.image_id, .generation = 1 },
        .format = frame.format,
        .width = frame.width,
        .height = frame.height,
        .byte_len = frame.byte_len,
    };
    _ = metadata.validate(processor.graphics_storage_limit) catch return false;

    const child = switch (frame.medium) {
        .shared => shared_transfer.mapChildObject(frame.encoded_name, frame.byte_len),
        .file => shared_transfer.mapChildFile(frame.encoded_name, frame.byte_len),
    } orelse return false;
    defer child.close();
    const media = processor.media_allocator.allocator();
    const placeholder = media.alloc(u8, 1) catch return false;
    if (!processor.media_allocator.reserveManual(frame.byte_len)) {
        media.free(placeholder);
        return false;
    }
    const name = shared_transfer.freezeSharedPixels(child.pixels) orelse {
        processor.media_allocator.releaseManual(frame.byte_len);
        media.free(placeholder);
        return false;
    };
    const storage = shared_transfer.mapOwnObject(name, frame.byte_len) orelse {
        _ = std.c.shm_unlink(name.sliceZ());
        processor.media_allocator.releaseManual(frame.byte_len);
        media.free(placeholder);
        return false;
    };
    if (!processor.media_allocator.adoptMapping(placeholder, storage)) {
        std.posix.munmap(storage);
        _ = std.c.shm_unlink(name.sliceZ());
        processor.media_allocator.releaseManual(frame.byte_len);
        media.free(placeholder);
        return false;
    }

    processor.ingestMediaOutput(frame.bytes[0..frame.apc_start]);
    const images = &processor.media.terminal.screens.active.kitty_images;
    images.addImage(processor.io, media, processor.media.terminal.screens.active, .{
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
        processor.ingestMediaOutput(frame.bytes[frame.apc_end..]);
        return true;
    };
    var placement: [64]u8 = undefined;
    const command = std.fmt.bufPrint(
        &placement,
        "\x1b_Ga=p,i={d},p={d},C=1,q=2\x1b\\",
        .{ frame.image_id, frame.placement_id },
    ) catch unreachable;
    processor.ingestMediaOutput(command);
    processor.ingestMediaOutput(frame.bytes[frame.apc_end..]);

    const generation = images.imageById(frame.image_id).?.generation;
    var parked = metadata;
    parked.key.generation = generation;
    const transfer: shared_transfer.PreparedTransfer = .{
        .metadata = parked,
        .name = name,
        // The mapping's reservation belongs to emulator storage; the
        // parked name adds no bytes of its own.
        .reserved_len = 0,
    };
    if (processor.state.shared_transport_clients.load(.acquire) == 0 or
        !processor.state.prepared_transfers.put(transfer, processor.media_allocator))
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
fn answerFileQuery(processor: *Processor, query: media_mod.FileQueryView) bool {
    var reply: [64]u8 = undefined;
    const accepted = query.byte_len <= processor.graphics_storage_limit and
        shared_transfer.validateChildFile(query.encoded_path, query.byte_len);
    const bytes = std.fmt.bufPrint(&reply, "\x1b_Gi={d};{s}\x1b\\", .{
        query.image_id,
        if (accepted) "OK" else "EBADF:file not accepted",
    }) catch unreachable;
    processor.responses.write(bytes);
    return true;
}

fn ingestMediaOutput(processor: *Processor, bytes: []const u8) void {
    const loading_id = if (processor.media.terminal.screens.active.kitty_images.loading) |loading|
        loading.image.id
    else
        null;
    const kitty_commands = processor.state.kitty_framing.observe(bytes);
    processor.media.stream.nextSlice(bytes);
    processor.enforceIncompleteGraphics(.{
        .io = processor.io,
        .previous_loading_id = loading_id,
        .completed_commands = kitty_commands,
    });
}

fn enforceIncompleteGraphics(processor: *Processor, observation: GraphicsIngest) void {
    const io = observation.io;
    const previous_loading_id = observation.previous_loading_id;
    const completed_commands = observation.completed_commands;

    const storage = &processor.media.terminal.screens.active.kitty_images;
    if (previous_loading_id != null or storage.loading != null) {
        processor.state.kitty_loading_chunks +|= completed_commands;
    } else {
        processor.state.kitty_loading_chunks = 0;
    }

    const chunk_limit_exceeded = processor.state.kitty_loading_chunks > processor.graphics_limits.chunks_per_image;
    const loading = storage.loading orelse {
        if (chunk_limit_exceeded) {
            if (previous_loading_id) |image_id| {
                storage.delete(io, processor.media_allocator.allocator(), &processor.media.terminal, .{ .id = .{
                    .delete = true,
                    .image_id = image_id,
                } });
                processor.queueGraphicsLimitResponse(image_id);
            }
        }
        processor.state.kitty_loading_chunks = 0;
        return;
    };
    if (!chunk_limit_exceeded and
        loading.data.items.len <= processor.graphics_storage_limit)
    {
        return;
    }

    const image_id = loading.image.id;
    loading.destroy(processor.media_allocator.allocator());
    storage.loading = null;
    processor.state.kitty_loading_chunks = 0;
    processor.queueGraphicsLimitResponse(image_id);
}

pub fn queueGraphicsLimitResponse(processor: *Processor, image_id: u32) void {
    var response: [128]u8 = undefined;
    const bytes = std.fmt.bufPrint(
        &response,
        "\x1b_Gi={d};ENOMEM: graphics upload limit exceeded\x1b\\",
        .{image_id},
    ) catch return;
    processor.responses.write(bytes);
}
