//! Borrowed VT identities; lives only while the terminal's pages are stable.
const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const HyperlinkRef = @import("HyperlinkRef.zig");
const HyperlinkIndex = @This();

slots: [512]?u16 = @splat(null),
refs: [core.text_metadata_limits.max_links]HyperlinkRef = undefined,
previous: ?u16 = null,

/// Interns the VT identity, including its explicit id, across page boundaries.
/// Example: `const index = try identities.intern(&builder, reference);`
pub fn intern(index: *HyperlinkIndex, builder: *core.TextMetadataBuilder, reference: HyperlinkRef) !u16 {
    if (index.previous) |previous| {
        const previous_ref = index.refs[previous];
        if (previous_ref.page == reference.page and previous_ref.id == reference.id) {
            return previous;
        }
    }

    const entry = reference.page.hyperlink_set.get(reference.page.memory, reference.id);
    const uri = entry.uri.slice(reference.page.memory);
    if (uri.len > core.text_metadata_limits.max_uri_bytes) {
        return error.TextMetadataQuotaExceeded;
    }

    const hash = entry.hash(reference.page.memory);
    var slot: usize = @intCast(hash % index.slots.len);
    while (index.slots[slot]) |found| : (slot = (slot + 1) % index.slots.len) {
        const other = index.refs[found];
        if (entry.eql(reference.page.memory, other.page.hyperlink_set.get(other.page.memory, other.id), other.page.memory)) {
            index.previous = found;
            return found;
        }
    }

    const inserted = try builder.addLink(uri);
    index.refs[inserted] = reference;
    index.slots[slot] = inserted;
    index.previous = inserted;
    return inserted;
}
