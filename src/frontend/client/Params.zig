const core = @import("telar-core");
const client = @import("telar-client");
const std = @import("std");
const FastWrite = @import("resources/FastWrite.zig");
/// The platform resources a client cannot fabricate: everything else it
/// owns. Substituting these — a pipe for the tty's read handle, a
/// fixed-buffer writer, a scripted socket peer — is what makes the client
/// constructible in a test.
const Params = @This();

gpa: std.mem.Allocator,
io: std.Io,
connection: *core.SocketChannel,
input_file: std.Io.File,
writer: *std.Io.Writer,
async_output: bool = false,
fast_output: ?FastWrite = null,
/// Host terminal geometry measured by the platform adapter.
host_size: core.TerminalSize,
window_width_px: u32 = 0,
window_height_px: u32 = 0,
client_identity: core.ClientIdentity = @enumFromInt(1),
options: client.Options,
