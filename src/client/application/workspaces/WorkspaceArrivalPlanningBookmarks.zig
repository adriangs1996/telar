const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const Bookmark = @import("Bookmark.zig");
const Bookmarks = @This();

context: *anyopaque,
find: *const fn (*anyopaque, WorkspaceLocationType) ?Bookmark,
