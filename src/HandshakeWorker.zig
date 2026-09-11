const HandshakeWorker = @This();
const std = @import("std");
const core = @import("telar-core");
const source_namespace = @import("transport_integration_test.zig");
const backend = @import("telar-backend");
io: std.Io,
connection: *core.transport.SocketChannel,
supported: source_namespace.handshake.SchemaId,
response: ?source_namespace.handshake.ServerResponse = null,
failure: ?anyerror = null,

pub fn run(worker: *@This()) void {
    worker.response = backend.transport.handshake.performSchema(
        worker.io,
        worker.connection,
        worker.supported,
    ) catch |err| {
        worker.failure = err;
        return;
    };
}
