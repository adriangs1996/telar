const Context = @This();
const PresentationIngress = @import("PresentationIngress.zig");
const input = @import("../input/root.zig");
presentation_ingress: PresentationIngress = .{},
status_mode: input.hints.Mode = .normal,
geometry: @import("../workspace/root.zig").geometry.Region,
