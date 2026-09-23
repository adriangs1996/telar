const Compression = @import("Compression.zig");
const ImageState = @This();

external_id: u32 = 0,
transmitted: bool = false,
force_direct: bool = false,
compressed: ?[]u8 = null,
compression: ?*Compression = null,
incompressible: bool = false,
emitted_shared: bool = false,
transmitted_pass: u64 = 0,
transmitted_ns: u64 = 0,
host_acked: bool = false,
