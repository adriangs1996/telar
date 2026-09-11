pub fn Type(comptime Stream: type) type {
    return struct {
        host: []const u8,
        child: Stream,
        origin: Stream,
    };
}
