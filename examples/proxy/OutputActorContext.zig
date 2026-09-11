/// Drains the pty master onto the host terminal. This is herdr's PtyIoActor read
/// side: the tap runs here, in the actor, so only parsed events reach the main
/// loop rather than every byte of output.
const OutputActorContext = @This();
const source_namespace = @import("main.zig");
const std = @import("std");
const event = @import("event.zig");
io: source_namespace.Io,
allocator: std.mem.Allocator,
master: source_namespace.File,
host_tty: source_namespace.File,
rows: u16,
cols: u16,
queue: *event.Queue,
