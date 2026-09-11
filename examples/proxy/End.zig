const std = @import("std");
const tlsz = @import("tls");
const End = @This();

stream: std.Io.net.Stream,
in_buf: [tlsz.input_buffer_len]u8 = undefined,
out_buf: [tlsz.output_buffer_len]u8 = undefined,
reader: std.Io.net.Stream.Reader = undefined,
writer: std.Io.net.Stream.Writer = undefined,
conn: tlsz.Connection = undefined,

pub fn wire(self: *End, io: std.Io) void {
    self.reader = self.stream.reader(io, &self.in_buf);
    self.writer = self.stream.writer(io, &self.out_buf);
}

/// `Io.Reader`/`Io.Writer` collapse every transport failure into one
/// error and stash the real one on the side. A handshake that died
/// because the peer reset the socket and one that died because we sent
/// something wrong are very different findings, so dig the real error
/// back out before reporting.
pub fn concrete(self: *End, err: anyerror) anyerror {
    if (err == error.WriteFailed) {
        return self.writer.err orelse err;
    }
    if (err == error.ReadFailed) {
        return self.reader.err orelse err;
    }
    return err;
}
