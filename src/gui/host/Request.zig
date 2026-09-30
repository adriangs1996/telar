const Owner = @import("Owner.zig");
const event = @import("../input/event.zig");

state: State = .free,
kind: Kind = .read,
id: u64 = 0,
owner: Owner = .{},
bytes: [event.max_text_bytes]u8 = undefined,
len: usize = 0,

pub const Kind = enum(u32) { read = 1, write = 2 };
pub const State = enum { free, queued, active };
