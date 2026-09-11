const Client = @import("../../Client.zig");
const DiagnosticType = @import("telar-client").Diagnostic;
const EvaluationContext = @This();

client: *Client,
diagnostic: DiagnosticType = .{},
