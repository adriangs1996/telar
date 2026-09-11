const OptionalInteger = @This();
const lua = @import("lua-api").c;
index: c_int,
name: [*:0]const u8,
default: lua.lua_Integer,
