const core = @import("telar-core");
const std = @import("std");
const OptionsType = @import("Options.zig");
/// What the shared client cannot fabricate: allocators, the runtime
/// connection, identity, options and the workbench grid metrics the adapter
/// measured. Ports are bound by the adapter after construction.
const ClientInit = @This();

gpa: std.mem.Allocator,
io: std.Io,
connection: *core.SocketChannel,
host_size: core.TerminalSize,
window_width_px: u32 = 0,
window_height_px: u32 = 0,
client_identity: core.ClientIdentity = @enumFromInt(1),
options: OptionsType,
