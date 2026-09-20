const ClientKey = @import("../../../history/ClientKey.zig");

context: *anyopaque,
drop: *const fn (*anyopaque, ClientKey) void,
