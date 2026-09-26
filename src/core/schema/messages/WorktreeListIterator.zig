const bytecodec = @import("bytecodec");
const Decoder = bytecodec.Decoder;
const WorktreeListEntry = @import("WorktreeListEntry.zig");
const worktree = @import("worktree.zig");
const WorktreeListIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(self: *WorktreeListIterator) !?WorktreeListEntry {
    if (self.remaining == 0) {
        return null;
    }

    self.remaining -= 1;
    return try worktree.decodeWorktreeListEntry(&self.decoder);
}
