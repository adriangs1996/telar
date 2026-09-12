const std = @import("std");
const SocketChannelType = @import("telar-core").SocketChannel;
const TerminalSizeType = @import("telar-core").TerminalSize;
const ClientIdentityType = @import("telar-core").ClientIdentity;
const OptionsType = @import("Options.zig");
/// What the shared client cannot fabricate: allocators, the runtime
/// connection, identity, options and the workbench grid metrics the adapter
/// measured. Ports are bound by the adapter after construction.
const ClientInit = @This();

gpa: std.mem.Allocator,
io: std.Io,
connection: *SocketChannelType,
host_size: TerminalSizeType,
window_width_px: u32 = 0,
window_height_px: u32 = 0,
client_identity: ClientIdentityType = @enumFromInt(1),
options: OptionsType,
