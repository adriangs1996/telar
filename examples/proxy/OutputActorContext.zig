const std = @import("std");
const event = @import("event.zig");
/// Drains the pty master onto the host terminal. This is herdr's PtyIoActor read
/// side: the tap runs here, in the actor, so only parsed events reach the main
/// loop rather than every byte of output.
const OutputActorContext = @This();

io: std.Io,
allocator: std.mem.Allocator,
master: std.Io.File,
host_tty: std.Io.File,
rows: u16,
cols: u16,
queue: *event.Queue,
