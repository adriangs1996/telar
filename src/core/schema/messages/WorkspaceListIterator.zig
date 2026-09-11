const DecoderType = @import("../Decoder.zig");
const WorkspaceListEntry = @import("WorkspaceListEntry.zig");
const workspace = @import("workspace.zig");
const WorkspaceListIterator = @This();

decoder: DecoderType,
remaining: u16,

pub fn next(iterator: *WorkspaceListIterator) !?WorkspaceListEntry {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    return try workspace.decodeWorkspaceListEntry(&iterator.decoder);
}
