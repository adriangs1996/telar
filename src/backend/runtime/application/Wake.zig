const core = @import("telar-core");
const ClientKeyType = @import("../../history/ClientKey.zig");
const Wake = @This();

client: ClientKeyType,
request_id: core.RequestId,
result: anyerror!void = {},
