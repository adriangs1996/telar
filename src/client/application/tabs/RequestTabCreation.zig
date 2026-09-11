const RequestTabCreation = @This();

/// Empty asks the runtime aggregate to generate its canonical label.
label: []const u8 = "",
/// Empty launches the client's default command; otherwise this argv runs
/// in the new tab. Borrowed only for the synchronous send callback.
arguments: []const []const u8 = &.{},
