const Session = @import("../../client/Session.zig");
context: *anyopaque,
pump: *const fn (*anyopaque, *Session) anyerror!void,
