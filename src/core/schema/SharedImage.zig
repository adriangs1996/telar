const id = @import("id.zig");
const ImageType = @import("../Image.zig");
const ShmNameType = @import("../ShmName.zig");
/// A complete image whose pixels live in a runtime-owned POSIX shared memory
/// object instead of the socket. Only the validated name crosses the wire;
/// the client maps the object read-only. Local transports only: the client
/// declares the capability explicitly before the runtime may use this.
const SharedImage = @This();

pane_id: id.PaneId,
revision: u64,
image: ImageType,
name: ShmNameType,
