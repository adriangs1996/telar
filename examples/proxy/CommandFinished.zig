const CommandFinished = @This();

/// Null means the shell published no usable status.
status: ?u8,
/// Resolved text of what the command printed. Allocated by the producing
/// actor and **owned by the receiver**, which must free it. Null when the
/// command printed nothing worth keeping.
output: ?[]const u8 = null,
/// The command printed more than the capture budget allowed.
truncated: bool = false,
