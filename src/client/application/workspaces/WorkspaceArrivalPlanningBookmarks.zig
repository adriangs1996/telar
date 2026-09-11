const Bookmarks = @This();
const source_namespace = @import("workspace_arrival_planning.zig");
const Bookmark = @import("Bookmark.zig");
context: *anyopaque,
find: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) ?Bookmark,
