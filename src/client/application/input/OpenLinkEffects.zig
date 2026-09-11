const FilePathType = @import("../../links/FilePath.zig");
const TargetType = @import("../../links/LinkTarget.zig");
const Effects = @This();

context: *anyopaque,
open_file: *const fn (*anyopaque, FilePathType) anyerror!void,
open_external: *const fn (*anyopaque, TargetType) anyerror!void,
