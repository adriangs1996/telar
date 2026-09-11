const ClientKeyType = @import("../../history/ClientKey.zig");
const RequestIdType = @import("telar-core").RequestId;
const Wake = @This();

client: ClientKeyType,
request_id: RequestIdType,
result: anyerror!void = {},
