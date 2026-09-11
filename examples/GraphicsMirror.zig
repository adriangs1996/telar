/// Latest-wins in-memory bridge from Ghostty VT storage to Telar's exterior
/// graphics store. Updating the store does not write to the host; its Kitty
/// writer alone owns and completes any open multipart stream.
const GraphicsMirror = @This();
const core = @import("telar-core");
const Emulator = @import("Emulator.zig");
const source_namespace = @import("terminal_browser_pane.zig");
const std = @import("std");
revision: u64 = 0,
image: ?core.graphics.ImageKey = null,
placement: ?core.graphics.Placement = null,

fn ready(mirror: *const GraphicsMirror, emulator: *const Emulator) bool {
    _ = mirror;
    const storage = &emulator.terminal.screens.active.kitty_images;
    return storage.dirty and storage.loading == null;
}

pub fn sync(mirror: *GraphicsMirror, emulator: *Emulator, store: *source_namespace.kitty.Store) !bool {
    if (!mirror.ready(emulator)) {
        return false;
    }
    const storage = &emulator.terminal.screens.active.kitty_images;
    mirror.revision +%= 1;
    if (mirror.revision == 0) {
        mirror.revision = 1;
    }
    const revision = mirror.revision;
    var next_image: ?struct {
        metadata: core.graphics.Image,
        pixels: []const u8,
    } = null;
    var images = storage.images.iterator();
    while (images.next()) |entry| {
        const image = entry.value_ptr;
        const pixels = image.data.bytes() orelse continue;
        const format: core.graphics.Format = switch (image.format) {
            .rgb => .rgb,
            .rgba => .rgba,
            else => continue,
        };
        const metadata: core.graphics.Image = .{
            .key = .{ .image_id = image.id, .generation = image.generation },
            .format = format,
            .width = image.width,
            .height = image.height,
            .byte_len = @intCast(pixels.len),
        };
        if (next_image != null) {
            return error.ExampleImageLimitExceeded;
        }
        next_image = .{ .metadata = metadata, .pixels = pixels };
    }

    if (next_image) |next| {
        if (mirror.image == null or !std.meta.eql(mirror.image.?, next.metadata.key)) {
            try store.applyImage(.{
                .pane_id = source_namespace.pane_id,
                .revision = revision,
                .image = next.metadata,
            });
            var offset: usize = 0;
            while (offset < next.pixels.len) {
                const take = @min(core.graphics.max_ipc_chunk_bytes, next.pixels.len - offset);
                try store.applyChunk(.{
                    .pane_id = source_namespace.pane_id,
                    .revision = revision,
                    .key = next.metadata.key,
                    .offset = offset,
                    .bytes = next.pixels[offset..][0..take],
                });
                offset += take;
            }
        }
    }

    var next_placement: ?core.graphics.Placement = null;
    if (next_image) |next| {
        var placements = storage.placements.iterator();
        while (placements.next()) |entry| {
            if (entry.key_ptr.image_id != next.metadata.key.image_id) {
                continue;
            }
            const image = storage.imageById(entry.key_ptr.image_id) orelse continue;
            const placement = source_namespace.media.placementValue(&emulator.terminal, .{
                .key = entry.key_ptr.*,
                .placement = entry.value_ptr.*,
                .image = image,
            }) orelse continue;
            if (next_placement != null) {
                return error.ExamplePlacementLimitExceeded;
            }
            next_placement = placement;
        }
    }

    if (next_placement) |next| {
        if (mirror.placement == null or !std.meta.eql(mirror.placement.?, next)) {
            try store.applyPlacement(.{
                .pane_id = source_namespace.pane_id,
                .revision = revision,
                .placement = next,
            });
        }
    }
    if (mirror.placement) |previous| {
        if (next_placement == null or previous.virtual_id != next_placement.?.virtual_id) {
            try store.deletePlacement(.{
                .pane_id = source_namespace.pane_id,
                .revision = revision,
                .key = previous.key,
                .virtual_id = previous.virtual_id,
                .placement_id = previous.placement_id,
            });
        }
    }
    if (mirror.image) |previous| {
        if (next_image == null or previous.image_id != next_image.?.metadata.key.image_id) {
            try store.deleteImage(.{
                .pane_id = source_namespace.pane_id,
                .revision = revision,
                .key = previous,
            });
        }
    }

    mirror.image = if (next_image) |next| next.metadata.key else null;
    mirror.placement = next_placement;
    storage.dirty = false;
    return true;
}
