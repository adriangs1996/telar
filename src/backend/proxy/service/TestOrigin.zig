const TestOrigin = @This();
const source_namespace = @import("service_test.zig");
listener: source_namespace.net.Server,
port: u16
