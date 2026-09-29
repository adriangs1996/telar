//! Pane images: turns the presented machine's retained Kitty graphics into
//! textures and resolved placements (`docs/flows/pane-images.md`).
//!
//! Everything here runs on the window thread and stays off the media path's
//! bulk work: it reads metadata, borrows pixels through leases and hands at
//! most `ImageUpload.uploads_in_flight` uploads to the backend, whose own
//! thread copies them. Nothing allocates.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const kitty_protocol = @import("kitty_protocol");
const GpuImages = @import("GpuImages.zig");
const ImagePlacement = @import("ImagePlacement.zig");
const PaneImages = @import("PaneImages.zig");
const ImageView = @import("ImageView.zig");
const ResolvedFrom = @import("ResolvedFrom.zig");
const native = @import("../native/native.zig");
const ImageUpload = @import("../native/ImageUpload.zig");

const retained = client.retained_graphics;
const Store = retained.Store;
const rgba_bytes = 4;
/// Generations of one image uploading at once: the next can start while the
/// previous finishes, so a stream turns one generation per frame into a
/// texture instead of one every few frames. Older generations never queue.
const uploads_per_image = 2;

/// Resolves the presented machine's placements when its images, its
/// textures or the cell size changed, then releases textures nothing needs.
/// Runs once per prepared frame, before the scene draws panes.
///
/// ```zig
/// pane_images.place(&gui.images, &gui.graphics_stores, .{ .machine = slot, .cell_width = 16, .cell_height = 32 });
/// ```
pub fn place(images: *PaneImages, stores: []Store, view: ImageView) void {
    images.frame += 1;
    const store = &stores[view.machine];
    const built: ResolvedFrom = .{
        .machine = view.machine,
        .ingress = store.ingressVersion(),
        .revision = images.revision,
        .cell_width = view.cell_width,
        .cell_height = view.cell_height,
    };

    if (images.built != null and std.meta.eql(images.built.?, built) and !store.damage) {
        markStandIns(images);
        return;
    }

    resolve(images, store, view);
    store.damage = false;
    images.built = built;
    sweep(images, stores);
}

/// Starts uploads for the resolved placements whose image has no texture
/// yet, within the in-flight bound and the GPU budget. Only the generation
/// the store holds now is ever requested, so a stream never queues a replay:
/// at most `uploads_per_image` of its newest generations are in flight.
///
/// ```zig
/// pane_images.start(&gui.images, &gui.graphics_stores, slot, now_ns);
/// ```
pub fn start(images: *PaneImages, stores: []Store, machine: u8, now_ns: u64) void {
    const store = &stores[machine];
    for (images.resolved()) |placement| {
        if (images.gpu.uploading >= ImageUpload.uploads_in_flight or images.upload_count >= images.uploads.len) {
            return;
        }

        const identity = identityOf(placement);
        if (images.gpu.find(machine, identity) != null or images.gpu.uploadsOf(machine, identity) == uploads_per_image) {
            continue;
        }

        const entry = store.images.getPtr(identity) orelse continue;
        if (entry.received != entry.pixels.len or entry.retire_pending) {
            continue;
        }

        const metadata = entry.metadata;
        const row = images.gpu.add(machine, identity) orelse
            (if (evictOne(images)) images.gpu.add(machine, identity) else null) orelse
            return;
        images.gpu.width[row] = metadata.width;
        images.gpu.height[row] = metadata.height;
        if (metadata.width > ImageUpload.max_side or metadata.height > ImageUpload.max_side) {
            // Stays failed: this image can never be a texture.
            continue;
        }

        const bytes = @as(usize, metadata.width) * metadata.height * rgba_bytes;
        if (bytes > GpuImages.budget or !reserve(images, bytes)) {
            images.gpu.remove(row);
            continue;
        }

        const lease = retained.retain(store, identity) catch {
            images.gpu.remove(row);
            continue;
        };

        images.gpu.residency[row] = .uploading;
        images.gpu.lease[row] = lease;
        images.gpu.started_ns[row] = now_ns;
        images.gpu.bytes[row] = bytes;
        images.gpu.resident_bytes += bytes;
        images.gpu.uploading += 1;
        images.uploads[images.upload_count] = .{
            .pixels = lease.pixels.ptr,
            .handle = GpuImages.handleOf(row),
            .width = metadata.width,
            .height = metadata.height,
            .bytes_per_pixel = @intCast(metadata.format.bytesPerPixel()),
        };
        images.upload_count += 1;
    }
}

/// Takes the backend's report for one upload: the pixels go back to their
/// store, which may now free them and return the runtime's credit. Returns
/// how long a successful upload took since `start` requested it.
///
/// ```zig
/// const elapsed = pane_images.finish(&gui.images, &gui.graphics_stores, handle, true, now_ns);
/// ```
pub fn finish(images: *PaneImages, stores: []Store, handle: u32, success: bool, now_ns: u64) ?u64 {
    const row = GpuImages.rowOf(handle) orelse return null;
    if (images.gpu.residency[row] != .uploading) {
        return null;
    }

    retained.release(&stores[images.gpu.machine[row]], images.gpu.lease[row]);
    images.gpu.uploading -= 1;
    images.revision +%= 1;
    if (success) {
        images.gpu.residency[row] = .ready;
        return now_ns -| images.gpu.started_ns[row];
    }

    images.gpu.residency[row] = .failed;
    images.gpu.resident_bytes -= images.gpu.bytes[row];
    images.gpu.bytes[row] = 0;
    return null;
}

/// Records which textures the prepared frame draws, so eviction spares them.
/// Example: `pane_images.noteDrawn(&gui.images, renderer.imageDraws());`.
pub fn noteDrawn(images: *PaneImages, draws: []const native.ImageDraw) void {
    for (draws) |draw| {
        const row = GpuImages.rowOf(draw.handle) orelse continue;
        images.gpu.used_frame[row] = images.frame;
    }
}

/// Moves pending uploads and releases into the frame the backend takes when
/// render returns, then forgets them; the arrays stay valid until the next
/// prepare. Example: `pane_images.handOff(&gui.images, out);`.
pub fn handOff(images: *PaneImages, frame: *native.Frame) void {
    frame.image_uploads = &images.uploads;
    frame.image_upload_count = images.upload_count;
    frame.image_releases = &images.releases;
    frame.image_release_count = images.release_count;
    images.upload_count = 0;
    images.release_count = 0;
}

/// Returns every lease after the backend stopped reading, before the stores
/// go away. Example: `pane_images.abandon(&gui.images, &gui.graphics_stores);`.
pub fn abandon(images: *PaneImages, stores: []Store) void {
    for (images.gpu.residency, 0..) |residency, row| {
        if (residency != .uploading) {
            continue;
        }

        retained.release(&stores[images.gpu.machine[row]], images.gpu.lease[row]);
        images.gpu.residency[row] = .failed;
        images.gpu.uploading -= 1;
    }
}

fn resolve(images: *PaneImages, store: *Store, view: ImageView) void {
    images.placement_count = 0;
    images.dropped = 0;
    var entries = store.placements.iterator();
    while (entries.next()) |entry| {
        const pane_id = entry.key_ptr.pane_id;
        if (!store.paneVisible(pane_id)) {
            continue;
        }

        const placement = entry.value_ptr.placement;
        const identity: client.ImageIdentity = .{
            .pane_id = pane_id,
            .image_id = placement.key.image_id,
            .generation = placement.key.generation,
        };
        const image = store.images.getPtr(identity) orelse continue;
        const source = placement.sourceRect(image.metadata) catch continue;
        const box = kitty_protocol.displayBox(.{
            .source_width = @intCast(source.width),
            .source_height = @intCast(source.height),
            .columns = placement.columns,
            .rows = placement.rows,
            .offset_x = placement.offset_x,
            .offset_y = placement.offset_y,
            .cell_width = view.cell_width,
            .cell_height = view.cell_height,
        });

        if (box.width == 0 or box.height == 0) {
            continue;
        }

        if (images.placement_count == images.placements.len) {
            images.dropped += 1;
            continue;
        }

        const texture = textureFor(images, view.machine, identity);
        images.placements[images.placement_count] = .{
            .pane_id = pane_id,
            .layer = kitty_protocol.displayLayer(placement.z_index),
            .z_index = placement.z_index,
            .image_id = identity.image_id,
            .generation = identity.generation,
            .virtual_id = placement.virtual_id,
            .handle = if (texture) |row| GpuImages.handleOf(row) else 0,
            .column = placement.x,
            .row = placement.y,
            .box = box,
            .uv = if (texture) |row| uvOf(&images.gpu, row, source) else @splat(0),
        };
        images.placement_count += 1;
    }

    std.mem.sort(ImagePlacement, images.placements[0..images.placement_count], {}, ImagePlacement.lessThan);
    markStandIns(images);
}

// The image's own texture once ready, else the newest ready generation of
// the same image, so a replaced frame keeps showing until the next arrives.
fn textureFor(images: *const PaneImages, machine: u8, identity: client.ImageIdentity) ?usize {
    if (images.gpu.find(machine, identity)) |row| {
        if (images.gpu.residency[row] == .ready) {
            return row;
        }
    }

    return images.gpu.findStandIn(machine, identity);
}

// A stand-in of another size shows whole: the new placement's source
// rectangle means nothing in the old image.
fn uvOf(gpu: *const GpuImages, row: usize, source: core.RectRect) [4]f32 {
    const width: f32 = @floatFromInt(gpu.width[row]);
    const height: f32 = @floatFromInt(gpu.height[row]);
    const source_x: f32 = @floatFromInt(source.x);
    const source_y: f32 = @floatFromInt(source.y);
    const source_width: f32 = @floatFromInt(source.width);
    const source_height: f32 = @floatFromInt(source.height);
    if (source_x + source_width > width or source_y + source_height > height) {
        return .{ 0, 0, 1, 1 };
    }

    return .{
        source_x / width,
        source_y / height,
        (source_x + source_width) / width,
        (source_y + source_height) / height,
    };
}

fn markStandIns(images: *PaneImages) void {
    for (images.resolved()) |placement| {
        const row = GpuImages.rowOf(placement.handle) orelse continue;
        images.gpu.used_frame[row] = images.frame;
    }
}

// Releases textures whose image left its store and that no placement uses
// as a stand-in this frame. Uploading rows wait for their report.
fn sweep(images: *PaneImages, stores: []Store) void {
    for (images.gpu.residency, 0..) |residency, row| {
        if (residency != .ready and residency != .failed) {
            continue;
        }

        const store = &stores[images.gpu.machine[row]];
        if (store.images.getPtr(images.gpu.identity[row])) |entry| {
            if (!entry.retire_pending) {
                continue;
            }
        }

        if (images.gpu.used_frame[row] == images.frame) {
            continue;
        }

        release(images, row);
    }
}

// Makes room for `bytes` by releasing the least recently used textures the
// last frame did not draw.
fn reserve(images: *PaneImages, bytes: usize) bool {
    while (images.gpu.resident_bytes + bytes > GpuImages.budget) {
        if (!evictOne(images)) {
            return false;
        }
    }

    return true;
}

fn evictOne(images: *PaneImages) bool {
    var oldest: ?usize = null;
    for (images.gpu.residency, 0..) |residency, row| {
        if (residency != .ready or images.gpu.used_frame[row] + 1 >= images.frame) {
            continue;
        }

        if (oldest == null or images.gpu.used_frame[row] < images.gpu.used_frame[oldest.?]) {
            oldest = row;
        }
    }

    release(images, oldest orelse return false);
    return true;
}

fn release(images: *PaneImages, row: usize) void {
    images.releases[images.release_count] = GpuImages.handleOf(row);
    images.release_count += 1;
    images.gpu.remove(row);
    images.revision +%= 1;
}

fn identityOf(placement: ImagePlacement) client.ImageIdentity {
    return .{
        .pane_id = placement.pane_id,
        .image_id = placement.image_id,
        .generation = placement.generation,
    };
}
