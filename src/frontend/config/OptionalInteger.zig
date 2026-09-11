const lua_api = @import("lua-api");
const OptionalInteger = @This();

index: c_int,
name: [*:0]const u8,
default: lua_api.c.lua_Integer,
