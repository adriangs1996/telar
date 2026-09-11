/// A complete image whose pixels live in a runtime-owned POSIX shared memory
/// object instead of the socket. Only the validated name crosses the wire;
/// the client maps the object read-only. Local transports only: the client
/// declares the capability explicitly before the runtime may use this.
const SharedImage = @This();
const source_namespace = @import("graphics.zig");
const shared = @import("../graphics.zig");
pane_id: source_namespace.PaneId,
revision: u64,
image: shared.Image,
name: shared.ShmName,
