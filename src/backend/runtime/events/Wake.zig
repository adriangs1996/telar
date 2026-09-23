const core = @import("telar-core");
const ClientKey = @import("../../history/ClientKey.zig");
const Wake = @This();

client: ClientKey,
request_id: core.RequestId,
result: anyerror!void = {},
