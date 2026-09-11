const PacerContext = @This();
const frontend = @import("telar-frontend");
pacer: frontend.pace.Pacer = .{},
now_ns: u64 = 0,
