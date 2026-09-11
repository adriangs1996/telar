/// The platform resources a client cannot fabricate: everything else it
/// owns. Substituting these — a pipe for the tty's read handle, a
/// fixed-buffer writer, a scripted socket peer — is what makes the client
/// constructible in a test.
const Params = @This();
const std = @import("std");
const source_namespace = @import("Client.zig");
const core = @import("telar-core");
const host_output = @import("resources/host_output.zig");
const Options = @import("Options.zig");
gpa: std.mem.Allocator,
io: source_namespace.Io,
connection: *core.transport.SocketChannel,
input_file: source_namespace.File,
writer: *source_namespace.Io.Writer,
async_output: bool = false,
fast_output: ?host_output.FastWrite = null,
/// Host terminal geometry measured by the platform adapter.
host_size: source_namespace.schema.TerminalSize,
window_width_px: u32 = 0,
window_height_px: u32 = 0,
client_identity: source_namespace.schema.ClientIdentity = @enumFromInt(1),
options: Options,
