//! Borrowed VT identities; lives only while the terminal's pages are stable.
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const HyperlinkRef = @import("HyperlinkRef.zig");
const HyperlinkIndex = @This();

slots: [512]?u16 = @splat(null),
refs: [core.text_metadata_limits.max_links]HyperlinkRef = undefined,
page: ?*const vt.Page = null,
page_ids: [512]?vt.size.HyperlinkCountInt = @splat(null),
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
