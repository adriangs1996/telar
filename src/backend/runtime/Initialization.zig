/// Everything required to initialize one runtime at a stable address.
const Initialization = @This();
const Dependencies = @import("Dependencies.zig");
const Options = @import("Options.zig");
dependencies: Dependencies,
options: Options,
