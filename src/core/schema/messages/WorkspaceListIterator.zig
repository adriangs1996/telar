const bytecodec = @import("bytecodec");
const Decoder = bytecodec.Decoder;
const WorkspaceListEntry = @import("WorkspaceListEntry.zig");
const workspace = @import("workspace.zig");
const WorkspaceListIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(self: *WorkspaceListIterator) !?WorkspaceListEntry {
    if (self.remaining == 0) {
        return null;
    }
    self.remaining -= 1;
    return try workspace.decodeWorkspaceListEntry(&self.decoder);
}
