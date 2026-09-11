/// Creates the owned event delivered when one client send actor completes.
/// `Types` declares the client identity type.
///
/// ```zig
/// const Event = SentEvent(Types);
/// const event: Event = .{ .client = client, .result = {} };
/// ```
pub fn Type(comptime Types: type) type {
    return struct {
        client: Types.Client,
        result: anyerror!void,
    };
}
