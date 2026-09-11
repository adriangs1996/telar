const Options = @This();
const Dependencies = @import("Dependencies.zig");
const source_namespace = @import("root.zig");
dependencies: Dependencies,
child: source_namespace.net.Stream,
