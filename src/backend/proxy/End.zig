const std = @import("std");
const tlsz = @import("tls");
const End = @This();

stream: std.Io.net.Stream,
input_buffer: [tlsz.input_buffer_len]u8 = undefined,
output_buffer: [tlsz.output_buffer_len]u8 = undefined,
reader: std.Io.net.Stream.Reader = undefined,
writer: std.Io.net.Stream.Writer = undefined,
connection: tlsz.Connection = undefined,

pub fn wire(self: *End, io: std.Io) void {
    self.reader = self.stream.reader(io, &self.input_buffer);
    self.writer = self.stream.writer(io, &self.output_buffer);
}
