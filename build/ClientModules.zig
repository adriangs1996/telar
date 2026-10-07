const std = @import("std");
const LuaModules = @import("LuaModules.zig");
const Libraries = @import("Libraries.zig");

core: *std.Build.Module,
data: *std.Build.Module,
lua: LuaModules,
libraries: Libraries,
