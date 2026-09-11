const CellPresentation = @This();
const Projection = @import("telar-client").presentation.Projection;
const Resources = @import("Resources.zig");
const source_namespace = @import("Presenter.zig");
projection: Projection,
resources: Resources,
model: *const source_namespace.multiplexer.Model,
force: bool,
