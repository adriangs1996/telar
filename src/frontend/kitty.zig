//! Client-side Kitty graphics capability detection, storage, and emission.

const std = @import("std");
const core = @import("telar-core");
const multiplexer = @import("multiplexer.zig");
const term = @import("term.zig");
const theme = @import("theme.zig");

const Io = std.Io;
const schema = core.schema;
const graphics = core.graphics;

pub const query_image_id: u32 = 31;
pub const capability_timeout_ns: u64 = 250 * std.time.ns_per_ms;
pub const capability_query =
    "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\" ++
    "\x1b[14t\x1b[16t\x1b[?1016$p\x1b[c";

pub const Support = enum { unknown, unsupported, supported };

pub const TerminalCapabilities = struct {
    kitty_graphics: Support = .unknown,
    window_width_px: u32 = 0,
    window_height_px: u32 = 0,
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    mouse_pixels: Support = .unknown,

    pub fn observe(capabilities: *TerminalCapabilities, response: term.Event.TerminalResponse) bool {
        const before = capabilities.*;
        switch (response) {
            .kitty_graphics => |reply| {
                if (reply.image_id == query_image_id)
                    capabilities.kitty_graphics = if (reply.supported) .supported else .unsupported;
            },
            .window_pixels => |size| {
                capabilities.window_width_px = size.width;
                capabilities.window_height_px = size.height;
            },
            .cell_pixels => |size| {
                capabilities.cell_width_px = size.width;
                capabilities.cell_height_px = size.height;
            },
            .mouse_pixels => |reply| {
                capabilities.mouse_pixels = if (reply.supported) .supported else .unsupported;
            },
            // DA is sent after the KGP probe so terminal multiplexers flush
            // their response path. It does not prove that the preceding APC
            // was rejected: replies may be delivered in a different order.
            // Only the bounded capability timeout may turn unknown into
            // unsupported.
            .primary_device_attributes => {},
        }
        return !std.meta.eql(before, capabilities.*);
    }

    pub fn expire(capabilities: *TerminalCapabilities) bool {
        var changed = false;
        if (capabilities.kitty_graphics == .unknown) {
            capabilities.kitty_graphics = .unsupported;
            changed = true;
        }
        if (capabilities.mouse_pixels == .unknown) {
            capabilities.mouse_pixels = .unsupported;
            changed = true;
        }
        return changed;
    }

    pub fn cellSize(capabilities: *const TerminalCapabilities, cols: u16, rows: u16) struct {
        width: u16,
        height: u16,
    } {
        const width = if (capabilities.cell_width_px != 0)
            capabilities.cell_width_px
        else if (cols != 0)
            capabilities.window_width_px / cols
        else
            0;
        const height = if (capabilities.cell_height_px != 0)
            capabilities.cell_height_px
        else if (rows != 0)
            capabilities.window_height_px / rows
        else
            0;
        return .{
            .width = std.math.cast(u16, width) orelse 0,
            .height = std.math.cast(u16, height) orelse 0,
        };
    }
};

pub const SidebarRendering = enum {
    automatic,
    cells,
    kitty_hybrid,
    kitty_full,

    pub fn parse(name: []const u8) !SidebarRendering {
        if (std.ascii.eqlIgnoreCase(name, "automatic") or std.ascii.eqlIgnoreCase(name, "auto")) return .automatic;
        if (std.ascii.eqlIgnoreCase(name, "cells")) return .cells;
        if (std.ascii.eqlIgnoreCase(name, "kitty-hybrid")) return .kitty_hybrid;
        if (std.ascii.eqlIgnoreCase(name, "kitty-full")) return .kitty_full;
        return error.UnknownSidebarRenderer;
    }

    pub fn resolve(value: SidebarRendering, support: Support) !ResolvedSidebarRendering {
        return switch (value) {
            .automatic => if (support == .supported) .kitty_hybrid else .cells,
            .cells => .cells,
            .kitty_hybrid => if (support == .supported)
                .kitty_hybrid
            else if (support == .unknown)
                .cells
            else
                error.KittyGraphicsUnsupported,
            .kitty_full => if (support == .supported)
                .kitty_full
            else if (support == .unknown)
                .cells
            else
                error.KittyGraphicsUnsupported,
        };
    }
};

pub const ResolvedSidebarRendering = enum { cells, kitty_hybrid, kitty_full };

const ImageIdentity = struct {
    pane_id: schema.PaneId,
    image_id: u32,
    generation: u64,
};

const PlacementIdentity = struct {
    pane_id: schema.PaneId,
    virtual_id: u64,
};

const ImageEntry = struct {
    metadata: graphics.Image,
    pixels: []u8,
    received: usize = 0,
    chunks: usize = 0,
    external_id: u32,
    transmitted: bool = false,
};

const PlacementEntry = struct {
    placement: graphics.Placement,
    external_id: u32,
    emitted: bool = false,
    dirty: bool = true,
};

const Delete = union(enum) {
    image: u32,
    placement: struct { image_id: u32, placement_id: u32 },
};

pub const Store = struct {
    const PaneUsage = struct { count: usize = 0, bytes: usize = 0 };
    const RevisionState = struct {
        pane_id: schema.PaneId,
        latest: u64 = 0,
        snapshot: ?u64 = null,
        awaiting_snapshot: bool = false,
    };
    gpa: std.mem.Allocator,
    images: std.AutoHashMapUnmanaged(ImageIdentity, ImageEntry) = .{},
    placements: std.AutoHashMapUnmanaged(PlacementIdentity, PlacementEntry) = .{},
    delete_queue: [graphics.max_placements_per_pane * 2]Delete = undefined,
    delete_head: usize = 0,
    delete_len: usize = 0,
    delete_overflow: bool = false,
    total_bytes: usize = 0,
    next_image_id: u32 = 1,
    next_placement_id: u32 = 1,
    damage: bool = false,
    revisions: [schema.max_panes_per_tab]?RevisionState =
        [_]?RevisionState{null} ** schema.max_panes_per_tab,
    hidden_panes: [schema.max_panes_per_tab]?schema.PaneId =
        [_]?schema.PaneId{null} ** schema.max_panes_per_tab,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        var images = store.images.iterator();
        while (images.next()) |entry| store.gpa.free(entry.value_ptr.pixels);
        store.images.deinit(store.gpa);
        store.placements.deinit(store.gpa);
    }

    pub fn applySnapshot(store: *Store, message: schema.graphics.Snapshot) !void {
        const revision = try store.revisionState(message.pane_id);
        switch (message.phase) {
            .begin => {
                store.clearPaneData(message.pane_id);
                revision.latest = message.revision;
                revision.snapshot = message.revision;
                revision.awaiting_snapshot = false;
            },
            .end => {
                if (revision.snapshot != message.revision) {
                    revision.awaiting_snapshot = true;
                    revision.snapshot = null;
                    return error.GraphicsResyncRequired;
                }
                store.removeIncomplete(message.pane_id);
                revision.latest = message.revision;
                revision.snapshot = null;
            },
        }
    }

    pub fn applyImage(store: *Store, message: schema.graphics.Image) !void {
        if (!try store.acceptRevision(message.pane_id, message.revision)) return;
        const byte_len = try message.image.validate(graphics.max_image_bytes_per_pane);
        const key = identity(message.pane_id, message.image.key);
        const previous = store.images.get(key);
        const pane_usage = store.paneUsage(message.pane_id);
        const logical_count = store.paneLogicalImageCount(message.pane_id, message.image.key.image_id);
        const replacing = store.hasImageId(message.pane_id, message.image.key.image_id);
        if (previous == null and !replacing and logical_count >= graphics.max_images_per_pane)
            return error.GraphicsImageLimitExceeded;
        const previous_len = if (previous) |entry| entry.pixels.len else 0;
        const next_pane_bytes = std.math.add(
            usize,
            pane_usage.bytes - previous_len,
            byte_len,
        ) catch return error.GraphicsQuotaExceeded;
        if (next_pane_bytes > graphics.max_image_bytes_per_pane)
            return error.GraphicsQuotaExceeded;
        const next_total = std.math.add(
            usize,
            store.total_bytes - previous_len,
            byte_len,
        ) catch return error.GraphicsQuotaExceeded;
        if (next_total > graphics.max_image_bytes_global)
            return error.GraphicsQuotaExceeded;

        if (store.images.fetchRemove(key)) |removed| {
            store.total_bytes -= removed.value.pixels.len;
            store.gpa.free(removed.value.pixels);
            store.queueDelete(.{ .image = removed.value.external_id });
        }
        const pixels = try store.gpa.alloc(u8, byte_len);
        errdefer store.gpa.free(pixels);
        const external_id = try store.allocateImageId();
        try store.images.put(store.gpa, key, .{
            .metadata = message.image,
            .pixels = pixels,
            .external_id = external_id,
        });
        store.total_bytes += byte_len;
        store.damage = true;
    }

    pub fn applyChunk(store: *Store, message: schema.graphics.ImageChunk) !void {
        if (!try store.acceptRevision(message.pane_id, message.revision)) return;
        const entry = store.images.getPtr(identity(message.pane_id, message.key)) orelse
            return error.UnknownGraphicsImage;
        if (message.offset != entry.received) return error.InvalidGraphicsChunkOffset;
        if (entry.chunks == graphics.max_chunks_per_image)
            return error.GraphicsChunkLimitExceeded;
        const end = std.math.add(usize, entry.received, message.bytes.len) catch
            return error.InvalidGraphicsChunkLength;
        if (end > entry.pixels.len) return error.InvalidGraphicsChunkLength;
        @memcpy(entry.pixels[entry.received..end], message.bytes);
        entry.received = end;
        entry.chunks += 1;
        if (end == entry.pixels.len) {
            const key = entry.metadata.key;
            store.removeOtherGenerations(message.pane_id, key);
            store.damage = true;
        }
    }

    pub fn applyPlacement(store: *Store, message: schema.graphics.Placement) !void {
        if (!try store.acceptRevision(message.pane_id, message.revision)) return;
        const pane_id = message.pane_id;
        const placement = message.placement;
        const image = store.images.get(identity(pane_id, placement.key)) orelse
            return error.UnknownGraphicsImage;
        _ = try placement.sourceRect(image.metadata);
        const key: PlacementIdentity = .{ .pane_id = pane_id, .virtual_id = placement.virtual_id };
        if (store.placements.getPtr(key)) |entry| {
            if (entry.emitted) {
                const previous_image = store.images.get(identity(pane_id, entry.placement.key)).?;
                store.queueDelete(.{ .placement = .{
                    .image_id = previous_image.external_id,
                    .placement_id = entry.external_id,
                } });
            }
            entry.placement = placement;
            entry.dirty = true;
            entry.emitted = false;
        } else {
            if (store.panePlacementCount(pane_id) == graphics.max_placements_per_pane)
                return error.GraphicsPlacementLimitExceeded;
            try store.placements.put(store.gpa, key, .{
                .placement = placement,
                .external_id = try store.allocatePlacementId(),
            });
        }
        store.damage = true;
    }

    pub fn deleteImage(store: *Store, message: schema.graphics.DeleteImage) !void {
        if (!try store.acceptRevision(message.pane_id, message.revision)) return;
        store.deleteImageData(message.pane_id, message.key);
    }

    fn deleteImageData(store: *Store, pane_id: schema.PaneId, key: graphics.ImageKey) void {
        const removed = store.images.fetchRemove(identity(pane_id, key)) orelse return;
        store.total_bytes -= removed.value.pixels.len;
        store.gpa.free(removed.value.pixels);
        store.queueDelete(.{ .image = removed.value.external_id });
        var iterator = store.placements.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id == pane_id and
                std.meta.eql(entry.value_ptr.placement.key, key))
                _ = store.placements.removeByPtr(entry.key_ptr);
        }
        store.damage = true;
    }

    pub fn deletePlacement(store: *Store, message: schema.graphics.DeletePlacement) !void {
        if (!try store.acceptRevision(message.pane_id, message.revision)) return;
        const key: PlacementIdentity = .{
            .pane_id = message.pane_id,
            .virtual_id = message.virtual_id,
        };
        const removed = store.placements.fetchRemove(key) orelse return;
        if (removed.value.emitted) if (store.images.get(identity(
            message.pane_id,
            removed.value.placement.key,
        ))) |image| store.queueDelete(.{ .placement = .{
            .image_id = image.external_id,
            .placement_id = removed.value.external_id,
        } });
        store.damage = true;
    }

    pub fn clearPane(store: *Store, pane_id: schema.PaneId) void {
        store.clearPaneData(pane_id);
        store.removeRevision(pane_id);
        store.setPaneVisible(pane_id, true) catch {};
    }

    fn clearPaneData(store: *Store, pane_id: schema.PaneId) void {
        var placements = store.placements.iterator();
        while (placements.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) continue;
            _ = store.placements.removeByPtr(entry.key_ptr);
        }
        var images = store.images.iterator();
        while (images.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) continue;
            store.total_bytes -= entry.value_ptr.pixels.len;
            store.gpa.free(entry.value_ptr.pixels);
            store.queueDelete(.{ .image = entry.value_ptr.external_id });
            _ = store.images.removeByPtr(entry.key_ptr);
        }
        store.damage = true;
    }

    pub fn invalidatePlacements(store: *Store) void {
        var iterator = store.placements.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.emitted) {
                const image = store.images.get(identity(
                    entry.key_ptr.pane_id,
                    entry.value_ptr.placement.key,
                )) orelse continue;
                store.queueDelete(.{ .placement = .{
                    .image_id = image.external_id,
                    .placement_id = entry.value_ptr.external_id,
                } });
            }
            entry.value_ptr.emitted = false;
            entry.value_ptr.dirty = true;
        }
        store.damage = true;
    }

    pub fn setPaneVisible(store: *Store, pane_id: schema.PaneId, visible: bool) !void {
        const hidden_index = store.hiddenPaneIndex(pane_id);
        if (!visible and hidden_index == null) {
            var inserted = false;
            for (&store.hidden_panes) |*slot| {
                if (slot.* != null) continue;
                slot.* = pane_id;
                inserted = true;
                break;
            }
            if (!inserted) return error.ClientPaneLimitExceeded;
        } else if (visible) {
            if (hidden_index) |index| store.hidden_panes[index] = null;
        }

        var iterator = store.placements.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) continue;
            if (!visible and entry.value_ptr.emitted) {
                const image = store.images.get(identity(
                    pane_id,
                    entry.value_ptr.placement.key,
                )) orelse continue;
                store.queueDelete(.{ .placement = .{
                    .image_id = image.external_id,
                    .placement_id = entry.value_ptr.external_id,
                } });
            }
            entry.value_ptr.emitted = false;
            entry.value_ptr.dirty = visible;
        }
        store.damage = true;
    }

    pub fn paneVisible(store: *const Store, pane_id: schema.PaneId) bool {
        return store.hiddenPaneIndex(pane_id) == null;
    }

    pub fn hasPaneGraphics(store: *const Store, pane_id: schema.PaneId) bool {
        var iterator = store.images.iterator();
        while (iterator.next()) |entry| if (entry.key_ptr.pane_id == pane_id) return true;
        return false;
    }

    fn allocateImageId(store: *Store) !u32 {
        if (store.next_image_id >= 0x40000000) return error.GraphicsIdExhausted;
        defer store.next_image_id += 1;
        return store.next_image_id;
    }

    fn allocatePlacementId(store: *Store) !u32 {
        if (store.next_placement_id >= 0x40000000) return error.GraphicsIdExhausted;
        defer store.next_placement_id += 1;
        return store.next_placement_id;
    }

    fn queueDelete(store: *Store, value: Delete) void {
        if (store.delete_len == store.delete_queue.len) {
            // Recover with one bounded range delete, then rebuild every
            // Telar-owned low-range image and placement. UI images live in the
            // high range and are not affected.
            store.delete_overflow = true;
            store.damage = true;
            return;
        }
        const index = (store.delete_head + store.delete_len) % store.delete_queue.len;
        store.delete_queue[index] = value;
        store.delete_len += 1;
    }

    fn popDelete(store: *Store) ?Delete {
        if (store.delete_len == 0) return null;
        const value = store.delete_queue[store.delete_head];
        store.delete_head = (store.delete_head + 1) % store.delete_queue.len;
        store.delete_len -= 1;
        return value;
    }

    fn paneUsage(store: *const Store, pane_id: schema.PaneId) PaneUsage {
        var result: PaneUsage = .{};
        var iterator = store.images.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) continue;
            result.count += 1;
            result.bytes += entry.value_ptr.pixels.len;
        }
        return result;
    }

    fn panePlacementCount(store: *const Store, pane_id: schema.PaneId) usize {
        var count: usize = 0;
        var iterator = store.placements.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id == pane_id) count += 1;
        }
        return count;
    }

    fn paneLogicalImageCount(store: *const Store, pane_id: schema.PaneId, replacing_id: u32) usize {
        var ids: [graphics.max_images_per_pane]u32 = undefined;
        var count: usize = 0;
        var replacing_present = false;
        var iterator = store.images.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) continue;
            if (entry.key_ptr.image_id == replacing_id) {
                replacing_present = true;
                continue;
            }
            var duplicate = false;
            for (ids[0..count]) |seen| {
                if (seen != entry.key_ptr.image_id) continue;
                duplicate = true;
                break;
            }
            if (duplicate) continue;
            ids[count] = entry.key_ptr.image_id;
            count += 1;
        }
        return count + @intFromBool(replacing_present);
    }

    fn hasImageId(store: *const Store, pane_id: schema.PaneId, image_id: u32) bool {
        var iterator = store.images.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id == pane_id and entry.key_ptr.image_id == image_id)
                return true;
        }
        return false;
    }

    fn removeOtherGenerations(
        store: *Store,
        pane_id: schema.PaneId,
        current: graphics.ImageKey,
    ) void {
        var obsolete: [graphics.max_images_per_pane]graphics.ImageKey = undefined;
        var count: usize = 0;
        var iterator = store.images.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id or
                entry.key_ptr.image_id != current.image_id or
                entry.key_ptr.generation == current.generation) continue;
            obsolete[count] = .{
                .image_id = entry.key_ptr.image_id,
                .generation = entry.key_ptr.generation,
            };
            count += 1;
        }
        for (obsolete[0..count]) |key| store.deleteImageData(pane_id, key);
    }

    fn removeIncomplete(store: *Store, pane_id: schema.PaneId) void {
        var placements = store.placements.iterator();
        while (placements.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) continue;
            const image = store.images.get(identity(
                pane_id,
                entry.value_ptr.placement.key,
            )) orelse {
                _ = store.placements.removeByPtr(entry.key_ptr);
                store.damage = true;
                continue;
            };
            if (image.received != image.pixels.len) {
                _ = store.placements.removeByPtr(entry.key_ptr);
                store.damage = true;
            }
        }
        var iterator = store.images.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id or
                entry.value_ptr.received == entry.value_ptr.pixels.len) continue;
            store.total_bytes -= entry.value_ptr.pixels.len;
            store.gpa.free(entry.value_ptr.pixels);
            store.queueDelete(.{ .image = entry.value_ptr.external_id });
            _ = store.images.removeByPtr(entry.key_ptr);
            store.damage = true;
        }
    }

    fn revisionState(store: *Store, pane_id: schema.PaneId) !*RevisionState {
        for (&store.revisions) |*slot| if (slot.*) |*state| {
            if (state.pane_id == pane_id) return state;
        };
        for (&store.revisions) |*slot| {
            if (slot.* != null) continue;
            slot.* = .{ .pane_id = pane_id };
            return &slot.*.?;
        }
        return error.ClientPaneLimitExceeded;
    }

    fn acceptRevision(store: *Store, pane_id: schema.PaneId, value: u64) !bool {
        const state = try store.revisionState(pane_id);
        if (state.awaiting_snapshot) return false;
        if (state.snapshot) |snapshot| {
            if (value != snapshot) {
                state.awaiting_snapshot = true;
                state.snapshot = null;
                return error.GraphicsResyncRequired;
            }
            return true;
        }
        if (value < state.latest) return false;
        state.latest = value;
        return true;
    }

    fn removeRevision(store: *Store, pane_id: schema.PaneId) void {
        for (&store.revisions) |*slot| if (slot.*) |state| {
            if (state.pane_id == pane_id) slot.* = null;
        };
    }

    fn hiddenPaneIndex(store: *const Store, pane_id: schema.PaneId) ?usize {
        for (store.hidden_panes, 0..) |slot, index| if (slot == pane_id) return index;
        return null;
    }
};

fn identity(pane_id: schema.PaneId, key: graphics.ImageKey) ImageIdentity {
    return .{ .pane_id = pane_id, .image_id = key.image_id, .generation = key.generation };
}

pub const KittyGraphicsWriter = struct {
    store: *Store,
    model: *multiplexer.Model,
    area: core.ui.Rect,
    cell_width: u16,
    cell_height: u16,

    pub fn writeOpaque(context: *anyopaque, writer: *Io.Writer) Io.Writer.Error!usize {
        const self: *KittyGraphicsWriter = @ptrCast(@alignCast(context));
        return self.write(writer);
    }

    pub fn write(self: *KittyGraphicsWriter, writer: *Io.Writer) Io.Writer.Error!usize {
        if (!self.store.damage or self.cell_width == 0 or self.cell_height == 0) return 0;
        var written: usize = 0;
        if (self.store.delete_overflow) {
            written += try writeDeleteImageRange(writer, 1, 0x3fffffff);
            self.store.delete_head = 0;
            self.store.delete_len = 0;
            self.store.delete_overflow = false;
            var reset_images = self.store.images.iterator();
            while (reset_images.next()) |entry| entry.value_ptr.transmitted = false;
            var reset_placements = self.store.placements.iterator();
            while (reset_placements.next()) |entry| {
                entry.value_ptr.emitted = false;
                entry.value_ptr.dirty = true;
            }
        }
        while (self.store.popDelete()) |deletion| written += switch (deletion) {
            .image => |image_id| try writeDeleteImage(writer, image_id),
            .placement => |placement| try writeDeletePlacement(
                writer,
                placement.image_id,
                placement.placement_id,
            ),
        };

        var images = self.store.images.iterator();
        while (images.next()) |entry| {
            if (!self.store.paneVisible(entry.key_ptr.pane_id)) continue;
            const image = entry.value_ptr;
            if (image.received != image.pixels.len or image.transmitted) continue;
            written += try writeTransmission(writer, image.external_id, image.metadata, image.pixels);
            image.transmitted = true;
        }

        var placements = self.store.placements.iterator();
        while (placements.next()) |entry| {
            if (!self.store.paneVisible(entry.key_ptr.pane_id)) continue;
            const placement = entry.value_ptr;
            if (!placement.dirty) continue;
            const image = self.store.images.get(identity(
                entry.key_ptr.pane_id,
                placement.placement.key,
            )) orelse continue;
            if (!image.transmitted) continue;
            const output = self.geometry(entry.key_ptr.pane_id, placement.placement, image.metadata) orelse {
                placement.dirty = false;
                continue;
            };
            written += try writePlacement(
                writer,
                image.external_id,
                placement.external_id,
                output,
                placement.placement.z_index,
            );
            placement.emitted = true;
            placement.dirty = false;
        }
        self.store.damage = false;
        return written;
    }

    fn geometry(
        self: *const KittyGraphicsWriter,
        pane_id: schema.PaneId,
        placement: graphics.Placement,
        image: graphics.Image,
    ) ?OutputPlacement {
        const view = self.model.viewForPane(pane_id, self.area) orelse return null;
        const source = placement.sourceRect(image) catch return null;
        const source_width: u32 = @intCast(source.width);
        const source_height: u32 = @intCast(source.height);
        const width, const height = destinationSize(
            placement,
            source_width,
            source_height,
            self.cell_width,
            self.cell_height,
        );
        if (width == 0 or height == 0) return null;
        const destination: graphics.Rect = .{
            .x = (@as(i64, view.content.x) + placement.x) * self.cell_width + placement.offset_x,
            .y = (@as(i64, view.content.y) + placement.y) * self.cell_height + placement.offset_y,
            .width = width,
            .height = height,
        };
        const bounds: graphics.Rect = .{
            .x = @as(i64, view.content.x) * self.cell_width,
            .y = @as(i64, view.content.y) * self.cell_height,
            .width = @as(u64, view.content.w) * self.cell_width,
            .height = @as(u64, view.content.h) * self.cell_height,
        };
        const clipped = graphics.clipScaled(destination, .{
            .x = source.x,
            .y = source.y,
            .width = source_width,
            .height = source_height,
        }, bounds) orelse return null;
        const pixel_x: u64 = @intCast(clipped.destination.x);
        const pixel_y: u64 = @intCast(clipped.destination.y);
        return .{
            .column = @intCast(pixel_x / self.cell_width),
            .row = @intCast(pixel_y / self.cell_height),
            .offset_x = @intCast(pixel_x % self.cell_width),
            .offset_y = @intCast(pixel_y % self.cell_height),
            .source_x = @intCast(clipped.source.x),
            .source_y = @intCast(clipped.source.y),
            .source_width = @intCast(clipped.source.width),
            .source_height = @intCast(clipped.source.height),
            .columns = @intCast(std.math.divCeil(u64, clipped.destination.width + pixel_x % self.cell_width, self.cell_width) catch 1),
            .rows = @intCast(std.math.divCeil(u64, clipped.destination.height + pixel_y % self.cell_height, self.cell_height) catch 1),
        };
    }
};

const OutputPlacement = struct {
    column: u32,
    row: u32,
    offset_x: u32,
    offset_y: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    columns: u32,
    rows: u32,
};

fn destinationSize(
    placement: graphics.Placement,
    source_width: u32,
    source_height: u32,
    cell_width: u16,
    cell_height: u16,
) struct { u64, u64 } {
    if (placement.columns == 0 and placement.rows == 0)
        return .{ source_width, source_height };
    if (placement.columns != 0 and placement.rows != 0) return .{
        @as(u64, placement.columns) * cell_width -| placement.offset_x,
        @as(u64, placement.rows) * cell_height -| placement.offset_y,
    };
    if (placement.columns != 0) {
        const width = @as(u64, placement.columns) * cell_width -| placement.offset_x;
        return .{ width, width * source_height / source_width };
    }
    const height = @as(u64, placement.rows) * cell_height -| placement.offset_y;
    return .{ height * source_width / source_height, height };
}

pub fn writeTransmission(
    writer: *Io.Writer,
    external_id: u32,
    image: graphics.Image,
    pixels: []const u8,
) Io.Writer.Error!usize {
    const Encoder = std.base64.standard.Encoder;
    const raw_chunk_size = 3072;
    var encoded: [4096]u8 = undefined;
    var offset: usize = 0;
    var first = true;
    var written: usize = 0;
    while (offset < pixels.len) {
        const take = @min(raw_chunk_size, pixels.len - offset);
        const payload = Encoder.encode(encoded[0..Encoder.calcSize(take)], pixels[offset..][0..take]);
        const more = offset + take < pixels.len;
        if (first) {
            const args = .{
                @intFromEnum(image.format), image.width, image.height, external_id, @intFromBool(more),
            };
            const format = "\x1b_Ga=t,f={d},s={d},v={d},t=d,i={d},q=2,m={d};";
            try writer.print(format, args);
            written += std.fmt.count(format, args);
            first = false;
        } else {
            const args = .{@intFromBool(more)};
            const format = "\x1b_Gm={d};";
            try writer.print(format, args);
            written += std.fmt.count(format, args);
        }
        try writer.writeAll(payload);
        try writer.writeAll("\x1b\\");
        written += payload.len + 2;
        offset += take;
    }
    return written;
}

pub fn writePlacement(
    writer: *Io.Writer,
    image_id: u32,
    placement_id: u32,
    value: OutputPlacement,
    child_z: i32,
) Io.Writer.Error!usize {
    const cursor_args = .{ value.row + 1, value.column + 1 };
    const cursor_format = "\x1b[{d};{d}H";
    try writer.print(cursor_format, cursor_args);
    const z = std.math.clamp(child_z, -1000, 1000);
    const args = .{ image_id, placement_id, value.source_x, value.source_y, value.source_width, value.source_height, value.columns, value.rows, value.offset_x, value.offset_y, z };
    const format = "\x1b_Ga=p,i={d},p={d},x={d},y={d},w={d},h={d},c={d},r={d},X={d},Y={d},z={d},C=1,q=2\x1b\\";
    try writer.print(format, args);
    return std.fmt.count(cursor_format, cursor_args) + std.fmt.count(format, args);
}

pub fn writeDeleteImage(writer: *Io.Writer, image_id: u32) Io.Writer.Error!usize {
    const args = .{image_id};
    const format = "\x1b_Ga=d,d=I,i={d},q=2\x1b\\";
    try writer.print(format, args);
    return std.fmt.count(format, args);
}

pub fn writeDeletePlacement(writer: *Io.Writer, image_id: u32, placement_id: u32) Io.Writer.Error!usize {
    const args = .{ image_id, placement_id };
    const format = "\x1b_Ga=d,d=i,i={d},p={d},q=2\x1b\\";
    try writer.print(format, args);
    return std.fmt.count(format, args);
}

pub fn writeDeleteImageRange(writer: *Io.Writer, first: u32, last: u32) Io.Writer.Error!usize {
    const args = .{ first, last };
    const format = "\x1b_Ga=d,d=R,x={d},y={d},q=2\x1b\\";
    try writer.print(format, args);
    return std.fmt.count(format, args);
}

/// Two reusable raster layers for the hybrid sidebar. Text and hit targets
/// remain in the cell renderer; these layers only provide the stable panel and
/// selected-row decoration beneath it.
pub const KittySidebarRenderer = struct {
    const background_id: u32 = 0x80000001;
    const selection_id: u32 = 0x80000002;
    const background_placement_id: u32 = 0x80000001;
    const selection_placement_id: u32 = 0x80000002;

    gpa: std.mem.Allocator,
    background: []u8 = &.{},
    selection: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    row_height: u32 = 0,
    area: core.ui.Rect = .{},
    selected_row: ?u16 = null,
    background_dirty: bool = false,
    selection_dirty: bool = false,
    placements_dirty: bool = false,
    visible: bool = false,
    emitted: bool = false,
    palette: ?theme.Palette = null,

    pub fn init(gpa: std.mem.Allocator) KittySidebarRenderer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(renderer: *KittySidebarRenderer) void {
        if (renderer.background.len != 0) renderer.gpa.free(renderer.background);
        if (renderer.selection.len != 0) renderer.gpa.free(renderer.selection);
    }

    pub fn prepare(
        renderer: *KittySidebarRenderer,
        area: core.ui.Rect,
        palette: *const theme.Palette,
        selected_row: ?u16,
        cell_width: u16,
        cell_height: u16,
    ) !void {
        if (area.isEmpty() or cell_width == 0 or cell_height == 0) {
            renderer.visible = false;
            renderer.placements_dirty = renderer.emitted;
            return;
        }
        const width = std.math.mul(u32, area.w, cell_width) catch return error.SidebarTooLarge;
        const height = std.math.mul(u32, area.h, cell_height) catch return error.SidebarTooLarge;
        const background_len = try rgbaLength(width, height);
        const selection_len = try rgbaLength(width -| 2 * cell_width, cell_height);
        const resized = renderer.width != width or renderer.height != height or
            renderer.row_height != cell_height;
        const palette_changed = renderer.palette == null or
            !std.meta.eql(renderer.palette.?, palette.*);
        if (palette_changed) {
            renderer.palette = palette.*;
            renderer.background_dirty = true;
            renderer.selection_dirty = true;
        }
        if (resized) {
            const next_background = try renderer.gpa.alloc(u8, background_len);
            errdefer renderer.gpa.free(next_background);
            const next_selection = try renderer.gpa.alloc(u8, selection_len);
            if (renderer.background.len != 0) renderer.gpa.free(renderer.background);
            if (renderer.selection.len != 0) renderer.gpa.free(renderer.selection);
            renderer.background = next_background;
            renderer.selection = next_selection;
            renderer.width = width;
            renderer.height = height;
            renderer.row_height = cell_height;
            renderer.background_dirty = true;
            renderer.selection_dirty = true;
            renderer.placements_dirty = true;
        }
        if (!std.meta.eql(renderer.area, area)) renderer.placements_dirty = true;
        if (renderer.selected_row != selected_row) {
            renderer.selected_row = selected_row;
            renderer.placements_dirty = true;
        }
        renderer.area = area;
        renderer.visible = true;

        if (renderer.background_dirty) {
            clearRgba(renderer.background);
            const color = rgba(palette.panel_bg, .{ 26, 26, 26, 245 });
            roundedRect(renderer.background, width, height, 0, 0, width, height, @min(cell_height / 2, 10), color);
            // A subtle right edge makes the panel boundary independent of the
            // font's box-drawing glyph metrics.
            roundedRect(renderer.background, width, height, width -| 2, 0, 2, height, 0, rgba(palette.overlay0, .{ 92, 92, 92, 255 }));
        }
        if (renderer.selection_dirty) {
            clearRgba(renderer.selection);
            const selection_width = width -| 2 * cell_width;
            roundedRect(
                renderer.selection,
                selection_width,
                cell_height,
                0,
                1,
                selection_width,
                cell_height -| 2,
                @min(cell_height / 3, 8),
                rgba(palette.surface0, .{ 35, 35, 35, 235 }),
            );
            // Graphical activity dot; the textual pane state remains cells.
            circle(
                renderer.selection,
                selection_width,
                cell_height,
                @min(cell_height / 2, selection_width -| 1),
                cell_height / 2,
                @max(@as(u32, 2), cell_height / 6),
                rgba(palette.accent, .{ 255, 199, 153, 255 }),
            );
        }
    }

    pub fn damaged(renderer: *const KittySidebarRenderer) bool {
        return renderer.background_dirty or renderer.selection_dirty or
            renderer.placements_dirty;
    }

    pub fn write(renderer: *KittySidebarRenderer, writer: *Io.Writer, cell_width: u16, cell_height: u16) Io.Writer.Error!usize {
        if (!renderer.damaged()) return 0;
        var written: usize = 0;
        if (!renderer.visible) {
            if (renderer.emitted) {
                written += try writeDeleteImage(writer, background_id);
                written += try writeDeleteImage(writer, selection_id);
            }
            renderer.emitted = false;
            renderer.background_dirty = false;
            renderer.selection_dirty = false;
            renderer.placements_dirty = false;
            return written;
        }
        if (renderer.background_dirty) written += try writeTransmission(writer, background_id, .{
            .key = .{ .image_id = background_id, .generation = 1 },
            .format = .rgba,
            .width = renderer.width,
            .height = renderer.height,
            .byte_len = renderer.background.len,
        }, renderer.background);
        if (renderer.selection_dirty) written += try writeTransmission(writer, selection_id, .{
            .key = .{ .image_id = selection_id, .generation = 1 },
            .format = .rgba,
            .width = renderer.width -| 2 * cell_width,
            .height = renderer.row_height,
            .byte_len = renderer.selection.len,
        }, renderer.selection);
        if (renderer.background_dirty or renderer.placements_dirty) {
            written += try writeDeletePlacement(writer, background_id, background_placement_id);
            written += try writePlacement(writer, background_id, background_placement_id, .{
                .column = renderer.area.x,
                .row = renderer.area.y,
                .offset_x = 0,
                .offset_y = 0,
                .source_x = 0,
                .source_y = 0,
                .source_width = renderer.width,
                .source_height = renderer.height,
                .columns = renderer.area.w,
                .rows = renderer.area.h,
            }, -10);
        }
        if (renderer.selection_dirty or renderer.placements_dirty) {
            written += try writeDeletePlacement(writer, selection_id, selection_placement_id);
            if (renderer.selected_row) |row| written += try writePlacement(writer, selection_id, selection_placement_id, .{
                .column = renderer.area.x + 1,
                .row = row,
                .offset_x = 0,
                .offset_y = 0,
                .source_x = 0,
                .source_y = 0,
                .source_width = renderer.width -| 2 * cell_width,
                .source_height = renderer.row_height,
                .columns = renderer.area.w -| 2,
                .rows = 1,
            }, -9);
        }
        renderer.background_dirty = false;
        renderer.selection_dirty = false;
        renderer.placements_dirty = false;
        renderer.emitted = true;
        _ = cell_height;
        return written;
    }
};

fn rgbaLength(width: u32, height: u32) !usize {
    const pixels = std.math.mul(usize, width, height) catch return error.SidebarTooLarge;
    return std.math.mul(usize, pixels, 4) catch return error.SidebarTooLarge;
}

fn clearRgba(pixels: []u8) void {
    @memset(pixels, 0);
}

fn rgba(color: core.ui.Color, fallback: [4]u8) [4]u8 {
    return switch (color) {
        .rgb => |value| .{ value[0], value[1], value[2], fallback[3] },
        else => fallback,
    };
}

fn roundedRect(
    pixels: []u8,
    stride_width: u32,
    stride_height: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    radius: u32,
    color: [4]u8,
) void {
    if (width == 0 or height == 0) return;
    const right = @min(stride_width, x +| width);
    const bottom = @min(stride_height, y +| height);
    var py = y;
    while (py < bottom) : (py += 1) {
        var px = x;
        while (px < right) : (px += 1) {
            const dx = @min(px - x, right - px - 1);
            const dy = @min(py - y, bottom - py - 1);
            if (dx < radius and dy < radius) {
                const rx = radius - dx;
                const ry = radius - dy;
                if (@as(u64, rx) * rx + @as(u64, ry) * ry > @as(u64, radius) * radius) continue;
            }
            setPixel(pixels, stride_width, px, py, color);
        }
    }
}

fn circle(pixels: []u8, width: u32, height: u32, cx: u32, cy: u32, radius: u32, color: [4]u8) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const dx = @as(i64, x) - cx;
            const dy = @as(i64, y) - cy;
            if (dx * dx + dy * dy <= @as(i64, radius) * radius)
                setPixel(pixels, width, x, y, color);
        }
    }
}

fn setPixel(pixels: []u8, width: u32, x: u32, y: u32, color: [4]u8) void {
    const index = (@as(usize, y) * width + x) * 4;
    pixels[index..][0..4].* = color;
}

test "capability query and replies are exact" {
    try std.testing.expectEqualStrings(
        "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[14t\x1b[16t\x1b[?1016$p\x1b[c",
        capability_query,
    );
    var capabilities: TerminalCapabilities = .{};
    try std.testing.expect(capabilities.observe(.{ .kitty_graphics = .{
        .image_id = 31,
        .supported = true,
    } }));
    try std.testing.expectEqual(Support.supported, capabilities.kitty_graphics);
}

test "automatic sidebar renderer falls back while capability is absent" {
    try std.testing.expectEqual(ResolvedSidebarRendering.cells, try SidebarRendering.automatic.resolve(.unknown));
    try std.testing.expectEqual(ResolvedSidebarRendering.cells, try SidebarRendering.automatic.resolve(.unsupported));
    try std.testing.expectEqual(ResolvedSidebarRendering.kitty_hybrid, try SidebarRendering.automatic.resolve(.supported));
    try std.testing.expectError(error.KittyGraphicsUnsupported, SidebarRendering.kitty_hybrid.resolve(.unsupported));
}

test "direct transmission chunks payload without changing pixels" {
    var pixels: [3073]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @truncate(index);
    var output: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try writeTransmission(&writer, 9, .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 3073,
        .height = 1,
        .byte_len = pixels.len,
    }, &pixels);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b_Ga=t,f=32,s=3073,v=1,t=d,i=9,q=2,m=1;"));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b\\\x1b_Gm=0;") != null);
}

test "simulated exterior terminal selects support or timeout fallback" {
    var supported: TerminalCapabilities = .{};
    const event = term.parse("\x1b_Gi=31;OK\x1b\\").?.event.terminal_response;
    try std.testing.expect(supported.observe(event));
    try std.testing.expectEqual(Support.supported, supported.kitty_graphics);

    var silent: TerminalCapabilities = .{};
    try std.testing.expect(silent.expire());
    try std.testing.expectEqual(Support.unsupported, silent.kitty_graphics);
}

test "exterior IDs do not collide across panes with identical child IDs" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = @enumFromInt(1), .revision = 1, .image = metadata });
    try store.applyImage(.{ .pane_id = @enumFromInt(2), .revision = 1, .image = metadata });
    const first = store.images.get(identity(@enumFromInt(1), metadata.key)).?.external_id;
    const second = store.images.get(identity(@enumFromInt(2), metadata.key)).?.external_id;
    try std.testing.expect(first != second);
    try std.testing.expect(first < 0x40000000 and second < 0x40000000);
}

test "unchanged graphics emit no work and resize does not retransmit pixels" {
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 10, .rows = 5 });

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = @enumFromInt(1), .revision = 1, .image = metadata });
    try store.applyChunk(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .key = metadata.key,
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 255 },
    });
    try store.applyPlacement(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .placement = .{
            .key = metadata.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });
    var first_bytes: [4096]u8 = undefined;
    var first_writer = Io.Writer.fixed(&first_bytes);
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .model = &model,
        .area = .{ .w = 10, .h = 5 },
        .cell_width = 10,
        .cell_height = 20,
    };
    try std.testing.expect((try graphics_writer.write(&first_writer)) != 0);
    try std.testing.expect(std.mem.indexOf(u8, first_writer.buffered(), "a=t") != null);

    var idle_bytes: [64]u8 = undefined;
    var idle_writer = Io.Writer.fixed(&idle_bytes);
    try std.testing.expectEqual(@as(usize, 0), try graphics_writer.write(&idle_writer));

    store.invalidatePlacements();
    var resize_bytes: [1024]u8 = undefined;
    var resize_writer = Io.Writer.fixed(&resize_bytes);
    try std.testing.expect((try graphics_writer.write(&resize_writer)) != 0);
    try std.testing.expect(std.mem.indexOf(u8, resize_writer.buffered(), "a=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, resize_writer.buffered(), "a=t") == null);

    try store.setPaneVisible(@enumFromInt(1), false);
    var hidden_bytes: [1024]u8 = undefined;
    var hidden_writer = Io.Writer.fixed(&hidden_bytes);
    try std.testing.expect((try graphics_writer.write(&hidden_writer)) != 0);
    try std.testing.expect(std.mem.indexOf(u8, hidden_writer.buffered(), "a=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_writer.buffered(), "a=t") == null);

    try store.setPaneVisible(@enumFromInt(1), true);
    var visible_bytes: [1024]u8 = undefined;
    var visible_writer = Io.Writer.fixed(&visible_bytes);
    try std.testing.expect((try graphics_writer.write(&visible_writer)) != 0);
    try std.testing.expect(std.mem.indexOf(u8, visible_writer.buffered(), "a=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible_writer.buffered(), "a=t") == null);
}

test "image and placement deletes encode exactly and clear client state" {
    var output: [256]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try writeDeleteImage(&writer, 7);
    _ = try writeDeletePlacement(&writer, 7, 11);
    _ = try writeDeleteImageRange(&writer, 1, 9);
    try std.testing.expectEqualStrings(
        "\x1b_Ga=d,d=I,i=7,q=2\x1b\\" ++
            "\x1b_Ga=d,d=i,i=7,p=11,q=2\x1b\\" ++
            "\x1b_Ga=d,d=R,x=1,y=9,q=2\x1b\\",
        writer.buffered(),
    );

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = metadata });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = metadata.key,
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 4 },
    });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{
            .key = metadata.key,
            .virtual_id = 11,
            .placement_id = 11,
            .x = 0,
            .y = 0,
        },
    });
    try store.deletePlacement(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = metadata.key,
        .virtual_id = 11,
        .placement_id = 11,
    });
    try std.testing.expectEqual(@as(usize, 0), store.placements.count());
    try store.deleteImage(.{ .pane_id = pane_id, .revision = 3, .key = metadata.key });
    try std.testing.expectEqual(@as(usize, 0), store.images.count());
    try std.testing.expectEqual(@as(usize, 0), store.total_bytes);
}

test "client graphics store enforces image and chunk counts" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    for (0..graphics.max_images_per_pane) |index| {
        const image_id: u32 = @intCast(index + 1);
        try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = .{
            .key = .{ .image_id = image_id, .generation = 1 },
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = 4,
        } });
    }
    try std.testing.expectError(error.GraphicsImageLimitExceeded, store.applyImage(.{
        .pane_id = pane_id,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1000, .generation = 1 },
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = 4,
        },
    }));

    const entry = store.images.getPtr(.{
        .pane_id = pane_id,
        .image_id = 1,
        .generation = 1,
    }).?;
    entry.chunks = graphics.max_chunks_per_image;
    try std.testing.expectError(error.GraphicsChunkLimitExceeded, store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = .{ .image_id = 1, .generation = 1 },
        .offset = 0,
        .bytes = &.{1},
    }));

    try store.applyImage(.{ .pane_id = pane_id, .revision = 2, .image = .{
        .key = .{ .image_id = 1, .generation = 2 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    } });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = .{ .image_id = 1, .generation = 2 },
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 4 },
    });
    try std.testing.expectEqual(graphics.max_images_per_pane, store.images.count());
    try std.testing.expect(store.images.contains(.{
        .pane_id = pane_id,
        .image_id = 1,
        .generation = 2,
    }));
}

test "a completed newer generation replaces incomplete client image storage" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    } });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = .{ .image_id = 7, .generation = 1 },
        .offset = 0,
        .bytes = &.{1},
    });
    try store.applyImage(.{ .pane_id = pane_id, .revision = 2, .image = .{
        .key = .{ .image_id = 7, .generation = 2 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    } });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = .{ .image_id = 7, .generation = 2 },
        .offset = 0,
        .bytes = &.{ 5, 6, 7, 8 },
    });
    try std.testing.expectEqual(@as(usize, 1), store.images.count());
    try std.testing.expectEqual(@as(usize, 4), store.total_bytes);
    try std.testing.expect(store.images.contains(.{
        .pane_id = pane_id,
        .image_id = 7,
        .generation = 2,
    }));
}

test "graphics revisions ignore stale deltas and validate snapshots" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 5, .image = metadata });
    try store.deleteImage(.{ .pane_id = pane_id, .revision = 4, .key = metadata.key });
    try std.testing.expect(store.images.contains(identity(pane_id, metadata.key)));

    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 8, .phase = .begin });
    try std.testing.expectError(error.GraphicsResyncRequired, store.applyImage(.{
        .pane_id = pane_id,
        .revision = 9,
        .image = metadata,
    }));
    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 10, .phase = .begin });
    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 10, .phase = .end });
}

test "sidebar row movement reuses pixels and theme changes retransmit them" {
    var renderer = KittySidebarRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    const area: core.ui.Rect = .{ .x = 1, .y = 1, .w = 4, .h = 3 };
    const vesper = theme.builtin(.vesper).palette;
    const catppuccin = theme.builtin(.catppuccin).palette;

    try renderer.prepare(area, &vesper, 1, 4, 4);
    var initial_buffer: [8192]u8 = undefined;
    var initial = Io.Writer.fixed(&initial_buffer);
    _ = try renderer.write(&initial, 4, 4);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "a=t") != null);

    try renderer.prepare(area, &vesper, 2, 4, 4);
    var moved_buffer: [2048]u8 = undefined;
    var moved = Io.Writer.fixed(&moved_buffer);
    _ = try renderer.write(&moved, 4, 4);
    try std.testing.expect(std.mem.indexOf(u8, moved.buffered(), "a=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved.buffered(), "a=t") == null);

    try renderer.prepare(area, &catppuccin, 2, 4, 4);
    var themed_buffer: [8192]u8 = undefined;
    var themed = Io.Writer.fixed(&themed_buffer);
    _ = try renderer.write(&themed, 4, 4);
    try std.testing.expect(std.mem.indexOf(u8, themed.buffered(), "a=t") != null);
}
