const std = @import("std");
const SocketChannelType = @import("telar-core").SocketChannel;
const FastWriteType = @import("resources/FastWrite.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const ClientIdentityType = @import("telar-core").ClientIdentity;
const Options = @import("telar-client").Options;
/// The platform resources a client cannot fabricate: everything else it
/// owns. Substituting these — a pipe for the tty's read handle, a
/// fixed-buffer writer, a scripted socket peer — is what makes the client
/// constructible in a test.
const Params = @This();

gpa: std.mem.Allocator,
io: std.Io,
connection: *SocketChannelType,
input_file: std.Io.File,
writer: *std.Io.Writer,
async_output: bool = false,
fast_output: ?FastWriteType = null,
/// Host terminal geometry measured by the platform adapter.
host_size: TerminalSizeType,
window_width_px: u32 = 0,
window_height_px: u32 = 0,
client_identity: ClientIdentityType = @enumFromInt(1),
options: Options,
