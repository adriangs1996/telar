const Client = @import("../../AttachedClient.zig");
const DiagnosticType = @import("../../config/Diagnostic.zig");
const EvaluationContext = @This();

client: *Client,
diagnostic: DiagnosticType = .{},
