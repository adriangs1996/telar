const core = @import("telar-core");
const model_data = @import("model");
const Registration = @This();

request_id: core.RequestId,
continuation: model_data.RequestsContinuation,
