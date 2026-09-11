const Replacement = @This();
const lua_config = @import("../../config/root.zig");
diagnostic: lua_config.Diagnostic,
invalid_fallback: ?lua_config.Diagnostic = null,
