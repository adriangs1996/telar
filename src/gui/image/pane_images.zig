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
/// Released textures kept for an upload of the same size.
const spare_limit = 4;
/// A spare nobody reused for this long is released.
const spare_ttl_ns: u64 = 2 * std.time.ns_per_s;
/// A texture no frame drew for this long, as a hidden tab's or another
/// machine's, is released; its pixels stay in the store for a re-upload.
const idle_ttl_ns: u64 = 5 * std.time.ns_per_s;

/// Resolves the presented machine's placements when its images, its
/// textures or the cell size changed, then releases textures nothing needs
/// and trims idle ones. Runs once per prepared frame, before the scene.
///
/// ```zig
/// pane_images.place(&gui.images, &gui.graphics_stores, .{ .machine = slot, .cell_width = 16, .cell_height = 32 }, now_ns);
/// ```
pub fn place(images: *PaneImages, stores: []Store, view: ImageView, now_ns: u64) void {
    images.frame += 1;
    images.now_ns = now_ns;
    trim(images);
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
/// yet, within the in-flight bound and the GPU budget. Only the newest
/// complete generation the store holds is ever requested, so a stream never
/// queues a replay: at most `uploads_per_image` of its newest generations
/// are in flight.
///
/// ```zig
/// pane_images.start(&gui.images, &gui.graphics_stores, slot, now_ns);
/// ```
pub fn start(images: *PaneImages, stores: []Store, machine: u8, now_ns: u64) void {
    const store = &stores[machine];
    // Nothing to start unless the images, the textures or the uploads in
    // flight changed since the last pass: an echo frame costs nothing here.
    const started: [3]u64 = .{ store.ingressVersion(), images.revision, images.gpu.uploading };
    if (std.mem.eql(u64, &started, &images.started_from) and images.started_machine == machine) {
        return;
    }

    images.started_from = started;
    images.started_machine = machine;
    for (images.shown[0..images.shown_count]) |shown| {
        if (images.gpu.uploading >= ImageUpload.uploads_in_flight or images.upload_count >= images.uploads.len) {
            return;
        }

        // Latest wins: with a stream, a newer generation usually arrived
        // before the placement that will point at it, so the newest complete
        // generation of the image is what this placement shows next.
        const identity = newestComplete(store, shown.identity) orelse continue;
        if (images.gpu.find(machine, identity) != null or images.gpu.uploadsOf(machine, identity) == uploads_per_image) {
            continue;
        }

        const metadata = store.images.getPtr(identity).?.metadata;
        const bytes = @as(usize, metadata.width) * metadata.height * rgba_bytes;
        const row = takeRow(images, stores, .{
            .machine = machine,
            .identity = identity,
            .width = metadata.width,
            .height = metadata.height,
        }) orelse {
            // Out of budget or rows: textures the next frames stop drawing
            // become evictable without any revision changing, so retry.
            images.started_from = @splat(std.math.maxInt(u64));
            continue;
        };
        if (images.gpu.residency[row] == .failed and images.gpu.bytes[row] == 0 and
            (metadata.width > ImageUpload.max_side or metadata.height > ImageUpload.max_side))
        {
            // Stays failed: this image can never be a texture.
            continue;
        }

        const lease = retained.retain(store, identity) catch {
            images.gpu.remove(row);
            continue;
        };

        if (images.gpu.bytes[row] == 0) {
            images.gpu.bytes[row] = bytes;
            images.gpu.resident_bytes += bytes;
        }

        images.gpu.residency[row] = .uploading;
        images.gpu.lease[row] = lease;
        images.gpu.started_ns[row] = now_ns;
        images.gpu.used_ns[row] = now_ns;
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
        // Idle time counts from here, not from before the upload.
        images.gpu.residency[row] = .ready;
        images.gpu.used_ns[row] = now_ns;
        return now_ns -| images.gpu.started_ns[row];
    }

    images.gpu.residency[row] = .failed;
    images.gpu.resident_bytes -= images.gpu.bytes[row];
    images.gpu.bytes[row] = 0;
    return null;
}

/// Records which textures the prepared frame draws, so eviction spares them,
/// and counts each generation the first time a frame draws it.
/// Example: `pane_images.noteDrawn(&gui.images, renderer.imageDraws());`.
pub fn noteDrawn(images: *PaneImages, draws: []const native.ImageDraw) void {
    for (draws) |draw| {
        const row = GpuImages.rowOf(draw.handle) orelse continue;
        images.gpu.used_frame[row] = images.frame;
        images.gpu.used_ns[row] = images.now_ns;
        if (!images.gpu.presented[row]) {
            images.gpu.presented[row] = true;
            images.presented +%= 1;
        }
    }
}

/// Milliseconds until a spare or an idle texture should be released, or zero
/// when none waits: an idle window wakes to trim them.
/// Example: `const delay = pane_images.wakeupAfter(&gui.images, now_ns);`.
pub fn wakeupAfter(images: *const PaneImages, now_ns: u64) u32 {
    var earliest: ?u64 = null;
    for (images.gpu.rows()) |row| {
        const deadline = expiry(&images.gpu, row) orelse continue;
        earliest = if (earliest) |value| @min(value, deadline) else deadline;
    }

    const deadline = earliest orelse return 0;
    const remaining = deadline -| now_ns;
    return @intCast(@max(1, std.math.divCeil(u64, remaining, std.time.ns_per_ms) catch unreachable));
}

/// Whether a spare or idle texture is due for release, so the window
/// prepares a frame that carries it. Example: `if (pane_images.trimDue(&gui.images, now_ns)) draw();`.
pub fn trimDue(images: *const PaneImages, now_ns: u64) bool {
    for (images.gpu.rows()) |row| {
        const deadline = expiry(&images.gpu, row) orelse continue;
        if (deadline <= now_ns) {
            return true;
        }
    }

    return false;
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
    images.shown_count = 0;
    @memset(&images.shown_index, empty_shown);
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

        keep(
            images,
            .{
                .pane_id = pane_id,
                .layer = kitty_protocol.displayLayer(placement.z_index),
                .z_index = placement.z_index,
                .image_id = identity.image_id,
                .generation = identity.generation,
                .virtual_id = placement.virtual_id,
                .handle = 0,
                .column = placement.x,
                .row = placement.y,
                .box = box,
                .uv = @splat(0),
            },
            source,
        );
    }

    // Textures are looked for only for the placements kept, so `shown`
    // never holds an image no placement draws.
    for (images.placements[0..images.placement_count], images.sources[0..images.placement_count]) |*kept, source| {
        const identity: client.ImageIdentity = .{
            .pane_id = kept.pane_id,
            .image_id = kept.image_id,
            .generation = kept.generation,
        };
        const texture = images.shown[shownOf(images, view.machine, identity)].texture;
        kept.handle = if (texture) |row| GpuImages.handleOf(row) else 0;
        kept.uv = if (texture) |row| uvOf(&images.gpu, row, source) else @splat(0);
    }

    std.mem.sort(ImagePlacement, images.placements[0..images.placement_count], {}, ImagePlacement.lessThan);
    markStandIns(images);
}

// Keeps a visible placement. A full list keeps the placements painted
// highest, by layer then z-index: the new one replaces the lowest kept when
// it paints above it, and either way one counts in `dropped`. The list is a
// min-heap by that order until `resolve` sorts it for painting.
fn keep(images: *PaneImages, placement: ImagePlacement, source: core.RectRect) void {
    if (images.placement_count < images.placements.len) {
        const index = images.placement_count;
        images.placements[index] = placement;
        images.sources[index] = source;
        images.placement_count += 1;
        siftUp(images, index);
        return;
    }

    images.dropped += 1;
    if (!paintsBelow(images.placements[0], placement)) {
        return;
    }

    images.placements[0] = placement;
    images.sources[0] = source;
    siftDown(images, 0);
}

fn paintsBelow(left: ImagePlacement, right: ImagePlacement) bool {
    if (left.layer != right.layer) {
        return @intFromEnum(left.layer) < @intFromEnum(right.layer);
    }

    return left.z_index < right.z_index;
}

fn siftUp(images: *PaneImages, from: usize) void {
    var index = from;
    while (index > 0) {
        const parent = (index - 1) / 2;
        if (!paintsBelow(images.placements[index], images.placements[parent])) {
            return;
        }

        swapKept(images, index, parent);
        index = parent;
    }
}

fn siftDown(images: *PaneImages, from: usize) void {
    var index = from;
    const count = images.placement_count;
    while (true) {
        var lowest = index;
        const left = 2 * index + 1;
        const right = left + 1;
        if (left < count and paintsBelow(images.placements[left], images.placements[lowest])) {
            lowest = left;
        }

        if (right < count and paintsBelow(images.placements[right], images.placements[lowest])) {
            lowest = right;
        }

        if (lowest == index) {
            return;
        }

        swapKept(images, index, lowest);
        index = lowest;
    }
}

fn swapKept(images: *PaneImages, a: usize, b: usize) void {
    std.mem.swap(ImagePlacement, &images.placements[a], &images.placements[b]);
    std.mem.swap(core.RectRect, &images.sources[a], &images.sources[b]);
}

const empty_shown = std.math.maxInt(u16);

// The `shown` entry of a placement's image, added on first sight with the
// texture it draws: the newest ready generation of the image, its own once
// ready, a newer one a stream already delivered, or the previous one while
// the next uploads, so a replaced frame keeps showing until a newer is ready.
fn shownOf(images: *PaneImages, machine: u8, identity: client.ImageIdentity) usize {
    const key = (@as(u64, @intFromEnum(identity.pane_id)) << 32) ^ identity.image_id;
    var probe: usize = @intCast(std.hash.int(key) & (PaneImages.shown_index_len - 1));
    while (true) : (probe = (probe + 1) & (PaneImages.shown_index_len - 1)) {
        const index = images.shown_index[probe];
        if (index == empty_shown) {
            break;
        }

        const other = images.shown[index].identity;
        if (other.pane_id == identity.pane_id and other.image_id == identity.image_id) {
            return index;
        }
    }

    const index = images.shown_count;
    images.shown[index] = .{
        .identity = identity,
        .texture = images.gpu.findNewestReady(machine, identity),
    };
    images.shown_index[probe] = @intCast(index);
    images.shown_count += 1;
    return index;
}

// The newest generation of the placement's image the store holds whole and
// has not superseded. A complete generation nothing superseded is the
// newest, found without walking the store.
fn newestComplete(store: *Store, identity: client.ImageIdentity) ?client.ImageIdentity {
    if (store.images.getPtr(identity)) |own| {
        if (own.received == own.pixels.len and !own.retire_pending) {
            return identity;
        }
    }

    var newest: ?client.ImageIdentity = null;
    var entries = store.images.iterator();
    while (entries.next()) |entry| {
        const key = entry.key_ptr.*;
        const image = entry.value_ptr;
        if (key.pane_id != identity.pane_id or key.image_id != identity.image_id or
            image.received != image.pixels.len or image.retire_pending)
        {
            continue;
        }

        if (newest == null or newest.?.generation < key.generation) {
            newest = key;
        }
    }

    return newest;
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
        images.gpu.used_ns[row] = images.now_ns;
    }
}

// When a spare or a ready texture falls out of use, if it can.
fn expiry(gpu: *const GpuImages, row: usize) ?u64 {
    return switch (gpu.residency[row]) {
        .spare => gpu.used_ns[row] +| spare_ttl_ns,
        .ready => gpu.used_ns[row] +| idle_ttl_ns,
        .free, .uploading, .failed => null,
    };
}

// Releases spares nobody reused and textures no frame drew for a while.
fn trim(images: *PaneImages) void {
    var index: usize = 0;
    while (index < images.gpu.count) {
        const row = images.gpu.rows()[index];
        const deadline = expiry(&images.gpu, row) orelse {
            index += 1;
            continue;
        };
        if (deadline > images.now_ns or images.gpu.used_frame[row] == images.frame) {
            index += 1;
            continue;
        }

        // Removing moves the last row into `index`; look at it next.
        discard(images, row);
    }
}

// Releases textures whose image left its store and that no placement uses
// as a stand-in this frame. Uploading rows wait for their report.
fn sweep(images: *PaneImages, stores: []Store) void {
    var index: usize = 0;
    while (index < images.gpu.count) {
        const row = images.gpu.rows()[index];
        const residency = images.gpu.residency[row];
        index += 1;
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

        retire(images, row);
        // A row that left the dense list moved another into its place.
        if (images.gpu.residency[row] == .free) {
            index -= 1;
        }
    }
}

// Picks the row an upload of this image uses: a spare of the same size,
// whose texture the backend rewrites in place, else a new row within the
// budget, evicting what the last frame did not draw.
fn takeRow(images: *PaneImages, stores: []Store, wanted: Wanted) ?usize {
    if (images.gpu.findSpare(wanted.width, wanted.height)) |spare| {
        images.gpu.assign(spare, wanted.machine, wanted.identity);
        return spare;
    }

    const bytes = @as(usize, wanted.width) * wanted.height * rgba_bytes;
    if (wanted.width <= ImageUpload.max_side and wanted.height <= ImageUpload.max_side and !reserve(images, stores, bytes)) {
        return null;
    }

    const row = images.gpu.add(wanted.machine, wanted.identity) orelse
        (if (evictOne(images)) images.gpu.add(wanted.machine, wanted.identity) else null) orelse
        return null;
    images.gpu.width[row] = wanted.width;
    images.gpu.height[row] = wanted.height;
    return row;
}

const Wanted = struct {
    machine: u8,
    identity: client.ImageIdentity,
    width: u32,
    height: u32,
};

// Makes room for `bytes` within the quota the stores' retained pixels share
// with the textures, evicting spares, then textures the last frame did not
// draw.
fn reserve(images: *PaneImages, stores: []Store, bytes: usize) bool {
    var retained_bytes: usize = 0;
    for (stores) |*store| {
        retained_bytes += store.total_bytes;
    }

    while (images.gpu.resident_bytes + retained_bytes + bytes > GpuImages.budget) {
        if (!evictOne(images)) {
            return false;
        }
    }

    return true;
}

fn evictOne(images: *PaneImages) bool {
    var oldest: ?usize = null;
    for (images.gpu.rows()) |row| {
        const residency = images.gpu.residency[row];
        const evictable = residency == .spare or
            (residency == .ready and images.gpu.used_frame[row] + 1 < images.frame);
        if (!evictable) {
            continue;
        }

        if (oldest == null or images.gpu.used_ns[row] < images.gpu.used_ns[oldest.?]) {
            oldest = row;
        }
    }

    discard(images, oldest orelse return false);
    return true;
}

// A texture leaving use becomes a spare while there is room for one, so the
// next upload of the same size rewrites it; otherwise it is released.
fn retire(images: *PaneImages, row: usize) void {
    if (images.gpu.residency[row] == .ready and images.gpu.spares < spare_limit) {
        images.gpu.residency[row] = .spare;
        images.gpu.spares += 1;
        images.gpu.used_ns[row] = images.now_ns;
        images.revision +%= 1;
        return;
    }

    discard(images, row);
}

fn discard(images: *PaneImages, row: usize) void {
    images.releases[images.release_count] = GpuImages.handleOf(row);
    images.release_count += 1;
    images.gpu.remove(row);
    images.revision +%= 1;
}
