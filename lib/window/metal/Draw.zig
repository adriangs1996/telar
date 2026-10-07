const PrimitiveType = @import("PrimitiveType.zig").PrimitiveType;

primitive: PrimitiveType = .triangle,
vertex_start: usize = 0,
vertex_count: usize,
instance_count: usize = 1,
base_instance: usize = 0,
