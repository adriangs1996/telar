const core = @import("telar-core");
const backend = @import("telar-backend");
const std = @import("std");
const HandshakeWorker = @This();

io: std.Io,
connection: *core.SocketChannel,
supported: core.SchemaId,
response: ?core.ServerResponse = null,
failure: ?anyerror = null,

pub fn run(worker: *@This()) void {
    worker.response = backend.performSchema(
        worker.io,
        worker.connection,
        worker.supported,
    ) catch |err| {
        worker.failure = err;
        return;
    };
}
