const core = @import("telar-core");
const model_data = @import("../model.zig");

request_id: core.RequestId,
continuation: model_data.RequestsContinuation,
