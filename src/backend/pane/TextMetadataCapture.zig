//! Captures links before blit consumes dirty flags or the VT can move its pages.
const revisions = @import("../revisions.zig");
const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const HyperlinkRef = @import("HyperlinkRef.zig");
const TextMetadataCapture = @This();

current: core.TextMetadata,
scratch: core.TextMetadata,
cols: u16 = 0,
revision: u64 = 1,
/// A capture since the last `takeDropped` kept only the links that fit
/// `text_metadata.max_links` or its URI and run bounds.
links_dropped: bool = false,

pub const links_limit = core.Limit.declare("text_metadata.max_links", "links", core.text_metadata_limits.max_links);

pub fn init(allocator: std.mem.Allocator, rows: u16) !TextMetadataCapture {
    var current = try core.TextMetadata.init(allocator, rows);
    errdefer current.deinit(allocator);
    return .{ .current = current, .scratch = try core.TextMetadata.init(allocator, rows) };
}

pub fn deinit(self: *TextMetadataCapture, allocator: std.mem.Allocator) void {
    self.current.deinit(allocator);
    self.scratch.deinit(allocator);
}

/// The state must have just been updated while its terminal is exclusively borrowed.
/// Example: `try capture.update(allocator, &render_state);`
pub fn update(self: *TextMetadataCapture, allocator: std.mem.Allocator, state: *const vt.RenderState) !void {
    try self.current.reserve(allocator, state.rows);
    try self.scratch.reserve(allocator, state.rows);
    const previous = self.current.view();
    const rows = state.row_data.slice();
    const raw_rows = rows.items(.raw);
    const dirty = rows.items(.dirty);
    const resized = previous.rows.len != state.rows or self.cols != state.cols;
    var rebuild = resized or state.dirty == .full;
    var changed = rebuild;
    for (0..state.rows) |y| {
        const flags = rowFlags(state, y);
        if (resized or @as(u8, @bitCast(flags)) != @as(u8, @bitCast(previous.rows[y]))) {
            changed = true;
        }

        if (dirty[y] and (raw_rows[y].hyperlink or (!resized and previous.rows[y].hyperlinks))) {
            rebuild = true;
        }
    }

    if (!rebuild and !changed) {
        return;
    }

    const next = if (rebuild) self.collect(state) else flags_only: {
        self.scratch.replace(previous);
        for (0..state.rows) |y| {
            self.scratch.buffer[core.text_metadata_limits.header_size + y] = @bitCast(rowFlags(state, y));
        }

        break :flags_only self.scratch.view();
    };
    self.cols = state.cols;
    if (std.mem.eql(u8, previous.encoded, next.encoded)) {
        return;
    }

    self.current.replace(next);
    revisions.advance(&self.revision);
}

/// Whether a capture dropped links since the last call, clearing it.
///
/// ```zig
/// if (pane.text_metadata.takeDropped()) report(TextMetadataCapture.links_limit);
/// ```
pub fn takeDropped(self: *TextMetadataCapture) bool {
    defer self.links_dropped = false;
    return self.links_dropped;
}

fn collect(self: *TextMetadataCapture, state: *const vt.RenderState) core.TextMetadataView {
    var builder = core.TextMetadataBuilder.init(self.scratch.buffer, state.rows);
    for (0..state.rows) |y| {
        builder.setRow(@intCast(y), rowFlags(state, y));
    }

    if (collectLinks(&builder, state)) {
        return builder.finish(.complete);
    }

    self.links_dropped = true;
    return builder.finish(.partial);
}

/// Adds every link run of the visible rows, keeping the links and runs that
/// fit; a cell whose link does not fit stays unlinked. Returns false when
/// any was left out.
fn collectLinks(builder: *core.TextMetadataBuilder, state: *const vt.RenderState) bool {
    var identities: HyperlinkIndex = .{};
    var complete = true;
    const rows = state.row_data.slice();
    for (rows.items(.raw), rows.items(.pin), rows.items(.cells), 0..) |row, pin, cells, y| {
        if (!row.hyperlink) {
            continue;
        }

        const page = pin.node.page();
        var pending: ?core.TextLinkRun = null;
        for (cells.items(.raw), 0..) |cell, x| {
            const link_index = if (cell.hyperlink and cell.wide != .spacer_head) found: {
                const live = page.getRowAndCell(x, pin.y).cell;
                const id = page.lookupHyperlink(live) orelse break :found null;
                const reference: HyperlinkRef = .{
                    .page = page,
                    .id = id,
                };
                break :found identities.intern(builder, reference) catch {
                    complete = false;
                    break :found null;
                };
            } else null;
            const start: u32 = @intCast(y * state.cols + x);
            if (pending) |*run| {
                if (link_index != null and link_index.? == run.link_index and start == run.start + run.len) {
                    run.len += 1;
                    continue;
                }

                builder.addRun(run.*) catch return false;
                pending = null;
            }

            if (link_index) |index| {
                pending = .{ .start = start, .len = 1, .link_index = index };
            }
        }

        if (pending) |run| {
            builder.addRun(run) catch return false;
        }
    }

    return complete;
}

fn rowFlags(state: *const vt.RenderState, y: usize) core.TextRowFlags {
    const rows = state.row_data.slice();
    const row = rows.items(.raw)[y];
    const cells = rows.items(.cells)[y].items(.raw);
    return .{
        .wrap = row.wrap,
        .continuation = row.wrap_continuation,
        .wide_padding = row.wrap and cells.len != 0 and cells[cells.len - 1].wide == .spacer_head,
        .hyperlinks = row.hyperlink,
    };
}

/// Borrowed VT identities; lives only while the terminal's pages are stable.
const HyperlinkIndex = struct {
    slots: [512]?u16 = @splat(null),
    // SAFETY: intern writes a reference before storing its index in slots; reads require an occupied slot.
    refs: [core.text_metadata_limits.max_links]HyperlinkRef = undefined,
    page: ?*const vt.Page = null,
    page_ids: [512]?vt.size.HyperlinkCountInt = @splat(null),
    // SAFETY: intern fills the cached index whenever it fills page_ids; reads require a matching non-null page id.
    page_indexes: [512]u16 = undefined,

    /// Interns the VT identity, including its explicit id, across page boundaries.
    /// Example: `const index = try identities.intern(&builder, reference);`
    pub fn intern(self: *HyperlinkIndex, builder: *core.TextMetadataBuilder, reference: HyperlinkRef) !u16 {
        if (self.page != reference.page) {
            @memset(&self.page_ids, null);
            self.page = reference.page;
        }

        var page_slot: usize = reference.id % self.page_ids.len;
        while (self.page_ids[page_slot]) |id| : (page_slot = (page_slot + 1) % self.page_ids.len) {
            if (id == reference.id) {
                return self.page_indexes[page_slot];
            }
        }

        const entry = reference.page.hyperlink_set.get(reference.page.memory, reference.id);
        const uri = entry.uri.slice(reference.page.memory);
        if (uri.len > core.text_metadata_limits.max_uri_bytes) {
            return error.TextMetadataQuotaExceeded;
        }

        switch (entry.id) {
            .explicit => |id| {
                if (id.len > core.text_metadata_limits.max_uri_bytes) {
                    return error.TextMetadataQuotaExceeded;
                }
            },
            .implicit => {},
        }

        const hash = entry.hash(reference.page.memory);
        var slot: usize = @intCast(hash % self.slots.len);
        while (self.slots[slot]) |found| : (slot = (slot + 1) % self.slots.len) {
            const other = self.refs[found];
            if (entry.eql(reference.page.memory, other.page.hyperlink_set.get(other.page.memory, other.id), other.page.memory)) {
                self.page_ids[page_slot] = reference.id;
                self.page_indexes[page_slot] = found;
                return found;
            }
        }

        const inserted = try builder.addLink(uri);
        self.refs[inserted] = reference;
        self.slots[slot] = inserted;
        self.page_ids[page_slot] = reference.id;
        self.page_indexes[page_slot] = inserted;
        return inserted;
    }
};
