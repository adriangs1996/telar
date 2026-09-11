const std = @import("std");
const SocketChannelType = @import("telar-core").SocketChannel;
const SchemaIdType = @import("telar-core").SchemaId;
const ServerResponseType = @import("telar-core").ServerResponse;
const performSchema_module = @import("telar-backend").performSchema;
const HandshakeWorker = @This();

io: std.Io,
connection: *SocketChannelType,
supported: SchemaIdType,
response: ?ServerResponseType = null,
failure: ?anyerror = null,

pub fn run(worker: *@This()) void {
    worker.response = performSchema_module(
        worker.io,
        worker.connection,
        worker.supported,
    ) catch |err| {
        worker.failure = err;
        return;
    };
}
