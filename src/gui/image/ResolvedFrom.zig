//! What the resolved placements were built from; any change rebuilds them.
const ResolvedFrom = @This();

machine: u8,
ingress: u64,
revision: u64,
cell_width: u32,
cell_height: u32,
