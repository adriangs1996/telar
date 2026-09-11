const TapWorkerOptions = @This();

entry: [*:0]const u8,

/// Example: `const options = try TapWorkerOptions.parse(args);`.
pub fn parse(args: []const [*:0]const u8) !TapWorkerOptions {
    if (args.len != 1) {
        return error.InvalidTapWorkerArguments;
    }

    return .{ .entry = args[0] };
}
