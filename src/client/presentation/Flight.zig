const lifecycle = @import("lifecycle.zig");
const ObservationType = @import("Observation.zig");
const GeometryType = @import("Geometry.zig");
const DeliveryType = @import("PresentationDelivery.zig");
const Flight = @This();

token: lifecycle.Token,
observation: ObservationType,
geometry: GeometryType,
delivery: DeliveryType,
