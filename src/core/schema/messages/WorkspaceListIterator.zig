const WorkspaceListIterator = @This();
const wire = @import("../wire.zig");
const WorkspaceListEntry = @import("WorkspaceListEntry.zig");
const source_namespace = @import("workspace.zig");
decoder: wire.Decoder,
remaining: u16,

pub fn next(iterator: *WorkspaceListIterator) !?WorkspaceListEntry {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    return try source_namespace.decodeWorkspaceListEntry(&iterator.decoder);
}
