const frontend = @import("telar-frontend");
const PacerContext = @This();

pacer: frontend.Pacer = .{},
now_ns: u64 = 0,
