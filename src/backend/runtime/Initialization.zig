const Dependencies = @import("Dependencies.zig");
const Options = @import("Options.zig");
/// Everything required to initialize one runtime at a stable address.
const Initialization = @This();

dependencies: Dependencies,
options: Options,
