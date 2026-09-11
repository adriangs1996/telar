const Command = @This();
const source_namespace = @import("presentation_delivery.zig");
commit: source_namespace.multiplexer.PresentationCommit,
media_pending: bool,
