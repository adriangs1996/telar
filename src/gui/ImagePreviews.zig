//! The window's clipboard image previews (docs/flows/clipboard-image.md):
//! the shared attachment catalog bound as the window client's
//! `AttachmentShelf`, and the decoded pixels behind each preview.
//! Thumbnails share one texture, a sheet with one cell per catalog slot;
//! the open preview's modal copy is a second texture. Both take the last two
//! diagram slots. Pixels change only in `beginFrame`, once the previous
//! native frame has completed. Retired pixels are zeroed and freed there
//! too, never on the key press that retired them.
const std = @import("std");
const data = @import("model");
const client = @import("telar-client");
const gfx = @import("gfx");
const native = @import("native/native.zig");
const diagram_texture = @import("native/DiagramTexture.zig");
const DiagramStore = @import("diagrams/Store.zig");
const PreviewImage = @import("image/PreviewImage.zig");
const PremultipliedImage = @import("image/PremultipliedImage.zig");
const preview_decode = @import("image/preview_decode.zig");
const ImagePreviews = @This();

pub const Catalog = client.GenericCatalog(Textures);

/// The diagram slots the previews take: the thumbnail sheet and the modal copy.
pub const sheet_slot: u8 = DiagramStore.capacity;
pub const modal_slot: u8 = DiagramStore.capacity + 1;

const cell_side = preview_decode.thumbnail_side;
const sheet_width = cell_side * data.attachment_types.max_items;

/// Pixels the previews add to one frame beside the diagrams.
pub const max_frame_pixels = sheet_width * cell_side + preview_decode.full_max_pixels;

/// Rows the shelf asks for below its pane, as the terminal shelf did.
const shelf_rows: u16 = 6;
const shelf_minimum_rows: u16 = 3;
const pane_minimum_rows: u16 = 3;

comptime {
    std.debug.assert(modal_slot < gfx.Quad.diagram_slot_count);
    std.debug.assert(diagram_texture.max_frame_pixels == DiagramStore.max_pixels + max_frame_pixels);
}

catalog: Catalog,
sheet: ?[]u8 = null,
sheet_version: u64 = 0,
/// The preview the capture worker decoded, until adoption takes it.
landing: ?PreviewImage = null,
/// Whether a capture worker runs; a request that arrives meanwhile waits.
capturing: bool = false,
queued: ?data.CaptureRequest = null,
/// Advances with every change the window must draw.
revision: u64 = 0,

/// Example: `gui.previews = .init(gpa);`
pub fn init(gpa: std.mem.Allocator) ImagePreviews {
    return .{
        .catalog = .init(gpa),
    };
}

/// Call after the capture worker has been joined.
/// Example: `gui.previews.deinit();`
pub fn deinit(self: *ImagePreviews) void {
    const gpa = self.catalog.gpa;
    self.catalog.delivery.borrowed = null;
    for (0..self.catalog.slots.len) |index| {
        if (self.catalog.slots[index] != null) {
            Textures.retireSlot(&self.catalog, index);
        }
    }

    self.catalog.deinit();
    self.freeRetired();
    self.dropLanding();
    if (self.sheet) |sheet| {
        std.crypto.secureZero(u8, sheet);
        gpa.free(sheet);
    }

    self.* = undefined;
}

/// The shelf the window binds to its own client.
/// Example: `app.attachments = gui.previews.port();`
pub fn port(self: *ImagePreviews) client.AttachmentShelf {
    return .{
        .context = self,
        .adopt_fn = adoptPreview,
        .reconcile_markers_fn = reconcileMarkers,
        .sync_target_fn = syncTarget,
        .remove_fn = removePreview,
        .remove_prompt_fn = removePromptPreviews,
        .modal_active_fn = modalActive,
        .close_modal_fn = closeModalPort,
        .reservation_fn = reservation,
        .visible_target_fn = visibleTarget,
        .plan_marker_removal_fn = planMarkerRemoval,
        .id_at_marker_deletion_fn = idAtMarkerDeletion,
        .pending_marker_at_deletion_fn = pendingMarkerAtDeletion,
        .expect_marker_deletion_fn = expectMarkerDeletion,
    };
}

/// Frees the pixels retired since the previous frame, then writes new
/// thumbnails into the sheet. Call only while no frame is in flight.
/// Example: `gui.previews.beginFrame();`
pub fn beginFrame(self: *ImagePreviews) void {
    self.catalog.delivery.borrowed = null;
    self.freeRetired();
    self.catalog.reapRetired();
    for (&self.catalog.slots, 0..) |*maybe_slot, index| {
        const slot = if (maybe_slot.*) |*value| value else continue;
        var thumbnail = slot.delivery.thumbnail orelse continue;
        const sheet = self.sheet orelse sheet: {
            const pixels = self.catalog.gpa.alloc(u8, @as(usize, sheet_width) * cell_side * 4) catch return;
            @memset(pixels, 0);
            self.sheet = pixels;
            break :sheet pixels;
        };

        writeCell(sheet, index, &thumbnail);
        slot.delivery.sheet_width = thumbnail.width;
        slot.delivery.sheet_height = thumbnail.height;
        thumbnail.deinit(self.catalog.gpa);
        slot.delivery.thumbnail = null;
        self.sheet_version +%= 1;
    }
}

/// The sheet and modal textures of this frame; empty while nothing shows.
/// Example: `renderer.diagrams[ImagePreviews.sheet_slot..][0..2].* = gui.previews.textures(shown);`
pub fn textures(self: *ImagePreviews, shown: bool) [2]native.DiagramTexture {
    var result: [2]native.DiagramTexture = @splat(.{});
    if (!shown or !self.catalog.hasVisibleItems()) {
        return result;
    }

    if (self.sheet) |sheet| {
        if (self.sheet_version != 0) {
            result[0] = .{
                .pixels = sheet.ptr,
                .width = sheet_width,
                .height = cell_side,
                .version = self.sheet_version,
            };
        }
    }

    const id = self.catalog.modal orelse return result;
    const slot = self.catalog.findConst(id) orelse return result;
    const full = slot.delivery.full orelse return result;
    self.catalog.delivery.borrowed = full.pixels.ptr;
    result[1] = .{
        .pixels = full.pixels.ptr,
        .width = full.width,
        .height = full.height,
        .version = @intFromEnum(id),
    };
    return result;
}

/// The part of the sheet that holds a preview's thumbnail, inset half a
/// texel so linear sampling never reaches the next cell.
/// Example: `const uv = previews.thumbnailUv(item.id) orelse continue;`
pub fn thumbnailUv(self: *const ImagePreviews, id: data.AttachmentId) ?[4]f32 {
    for (self.catalog.slots, 0..) |maybe_slot, index| {
        const slot = maybe_slot orelse continue;
        if (slot.id != id or slot.delivery.sheet_width == 0) {
            continue;
        }

        const left: f32 = @floatFromInt(index * cell_side);
        const width: f32 = @floatFromInt(sheet_width);
        const side: f32 = @floatFromInt(cell_side);
        return .{
            (left + 0.5) / width,
            0.5 / side,
            (left + @as(f32, @floatFromInt(slot.delivery.sheet_width)) - 0.5) / width,
            (@as(f32, @floatFromInt(slot.delivery.sheet_height)) - 0.5) / side,
        };
    }

    return null;
}

/// Whether the open preview has its modal copy to draw.
/// Example: `if (previews.modalReady()) try canvas.diagramAt(image, ImagePreviews.modal_slot);`
pub fn modalReady(self: *const ImagePreviews) bool {
    const id = self.catalog.modal orelse return false;
    const slot = self.catalog.findConst(id) orelse return false;
    return slot.delivery.full != null;
}

/// Opens one visible preview in the modal.
/// Example: `gui.previews.openModal(id);`
pub fn openModal(self: *ImagePreviews, id: data.AttachmentId) void {
    if (self.catalog.openModal(id)) {
        self.revision +%= 1;
    }
}

/// Example: `gui.previews.closeModal();`
pub fn closeModal(self: *ImagePreviews) void {
    if (self.catalog.closeModal()) {
        self.revision +%= 1;
    }
}

/// Frees a decoded preview adoption did not take: its capture went stale,
/// failed or was cancelled.
/// Example: `gui.previews.dropLanding();`
pub fn dropLanding(self: *ImagePreviews) void {
    if (self.landing) |*landing| {
        landing.deinit(self.catalog.gpa);
    }

    self.landing = null;
}

fn freeRetired(self: *ImagePreviews) void {
    const delivery = &self.catalog.delivery;
    for (delivery.retired[0..delivery.retired_len]) |*image| {
        image.deinit(self.catalog.gpa);
    }

    delivery.retired_len = 0;
}

fn writeCell(sheet: []u8, index: usize, thumbnail: *const PremultipliedImage) void {
    const row_bytes = @as(usize, sheet_width) * 4;
    const cell_bytes = @as(usize, cell_side) * 4;
    const left = index * cell_bytes;
    for (0..cell_side) |row| {
        const line = sheet[row * row_bytes + left ..][0..cell_bytes];
        @memset(line, 0);
        if (row < thumbnail.height) {
            const source = thumbnail.pixels[row * thumbnail.width * 4 ..][0 .. thumbnail.width * 4];
            @memcpy(line[0..source.len], source);
        }
    }
}

/// Per-slot pixels for the catalog. A slot's sheet cell is its index.
const Textures = struct {
    pub const SlotState = struct {
        full: ?PremultipliedImage = null,
        /// Waits here until `beginFrame` copies it into the sheet.
        thumbnail: ?PremultipliedImage = null,
        /// The thumbnail's size on the sheet; zero until it is written there.
        sheet_width: u32 = 0,
        sheet_height: u32 = 0,
    };

    pub const State = struct {
        /// The decoded preview adoption pairs with the slot it creates.
        incoming: ?PreviewImage = null,
        /// The modal copy the frame in flight samples.
        borrowed: ?[*]const u8 = null,
        /// Pixels retired since the last frame, freed by the next one.
        retired: [retired_capacity]PremultipliedImage = undefined,
        retired_len: u8 = 0,
    };

    /// Room for every slot's two images, twice over; more retirements
    /// between two frames free the oldest ones at once.
    const retired_capacity = data.attachment_types.max_items * 4;

    pub fn createSlot(store: *Catalog) !SlotState {
        const preview = store.delivery.incoming orelse return .{};
        store.delivery.incoming = null;
        return .{
            .full = preview.full,
            .thumbnail = preview.thumbnail,
        };
    }

    pub fn targetChanged(_: *Catalog) void {}

    pub fn retireSlot(store: *Catalog, index: usize) void {
        const slot = &store.slots[index].?;
        if (slot.delivery.thumbnail) |thumbnail| {
            retire(store, thumbnail);
        }

        if (slot.delivery.full) |full| {
            retire(store, full);
        }

        slot.delivery = .{};
    }

    fn retire(store: *Catalog, image: PremultipliedImage) void {
        const delivery = &store.delivery;
        if (delivery.retired_len == retired_capacity) {
            // At most one retired image is borrowed; free another now.
            const oldest: usize = if (delivery.retired[0].pixels.ptr == delivery.borrowed) 1 else 0;
            delivery.retired[oldest].deinit(store.gpa);
            delivery.retired[oldest] = delivery.retired[delivery.retired_len - 1];
            delivery.retired_len -= 1;
        }

        delivery.retired[delivery.retired_len] = image;
        delivery.retired_len += 1;
    }

    pub fn canRelease(_: *const Catalog.Slot) bool {
        return true;
    }
};

fn previews(context: *anyopaque) *ImagePreviews {
    return @ptrCast(@alignCast(context));
}

fn changed(self: *ImagePreviews, had_items: bool) bool {
    self.revision +%= 1;
    return had_items != self.catalog.hasVisibleItems();
}

fn adoptPreview(context: *anyopaque, capture: *data.Capture) anyerror!bool {
    const self = previews(context);
    if (self.landing) |landing| {
        if (landing.sequence == capture.request.sequence) {
            self.catalog.delivery.incoming = landing;
            self.landing = null;
        }
    }

    defer if (self.catalog.delivery.incoming) |*incoming| {
        incoming.deinit(self.catalog.gpa);
        self.catalog.delivery.incoming = null;
    };

    const had_items = self.catalog.hasVisibleItems();
    try self.catalog.adopt(capture);
    return changed(self, had_items);
}

fn reconcileMarkers(context: *anyopaque, target: data.AttachmentTarget, screen: client.MarkerScreen) ?bool {
    const self = previews(context);
    const had_items = self.catalog.hasVisibleItems();
    if (self.catalog.reconcileMarkers(target, screen) == 0) {
        return null;
    }

    return changed(self, had_items);
}

fn syncTarget(context: *anyopaque, target: ?data.AttachmentTarget) bool {
    const self = previews(context);
    const change = self.catalog.setTarget(target);
    if (change.changed) {
        self.revision +%= 1;
    }

    return change.changed and change.layout_changed;
}

fn removePreview(context: *anyopaque, id: data.AttachmentId) ?bool {
    const self = previews(context);
    const had_items = self.catalog.hasVisibleItems();
    if (!self.catalog.remove(id)) {
        return null;
    }

    return changed(self, had_items);
}

fn removePromptPreviews(context: *anyopaque, target: data.AttachmentTarget) ?bool {
    const self = previews(context);
    const had_items = self.catalog.hasVisibleItems();
    if (self.catalog.removeVisible(target) == 0) {
        return null;
    }

    return changed(self, had_items);
}

fn modalActive(context: *anyopaque) bool {
    return previews(context).catalog.hasModal();
}

fn closeModalPort(context: *anyopaque) bool {
    const self = previews(context);
    if (!self.catalog.closeModal()) {
        return false;
    }

    self.revision +%= 1;
    return true;
}

fn reservation(context: *anyopaque) ?data.PaneBottomReservation {
    const target = previews(context).catalog.visibleTarget() orelse return null;
    return .{
        .pane_id = target.pane_id,
        .preferred_height = shelf_rows,
        .minimum_height = shelf_minimum_rows,
        .minimum_pane_height = pane_minimum_rows,
    };
}

fn visibleTarget(context: *anyopaque) ?data.AttachmentTarget {
    return previews(context).catalog.visibleTarget();
}

fn planMarkerRemoval(context: *anyopaque, id: data.AttachmentId, screen: client.MarkerScreen) ?data.MarkerRemoval {
    return previews(context).catalog.planMarkerRemoval(id, screen);
}

fn idAtMarkerDeletion(context: *anyopaque, screen: client.MarkerScreen, deletion: data.AttachmentMarkerDeletion) ?data.AttachmentId {
    return previews(context).catalog.idAtMarkerDeletion(screen, deletion);
}

fn pendingMarkerAtDeletion(context: *anyopaque, screen: client.MarkerScreen, probe: client.DeletionProbe) bool {
    return previews(context).catalog.pendingMarkerAtDeletion(screen, probe);
}

fn expectMarkerDeletion(context: *anyopaque, target: data.AttachmentTarget) void {
    previews(context).catalog.expectMarkerDeletion(target);
}
