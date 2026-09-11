const h2 = @import("h2.zig");
const std = @import("std");
/// One direction's HPACK state. The dynamic table is per-direction and strictly
/// ordered, so a decoder must see every header block in sequence — which is
/// exactly what sitting inline gives us.
const Decoder = @This();

inflater: ?*h2.c.nghttp2_hd_inflater = null,
/// Header blocks can span CONTINUATION frames; they are only inflated once
/// END_HEADERS arrives.
block: std.ArrayList(u8) = .empty,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator) !Decoder {
    var self: Decoder = .{ .gpa = gpa };
    if (h2.c.nghttp2_hd_inflate_new(&self.inflater) != 0) {
        return error.InflaterFailed;
    }
    return self;
}

pub fn deinit(self: *Decoder) void {
    if (self.inflater) |inf| {
        h2.c.nghttp2_hd_inflate_del(inf);
    }
    self.block.deinit(self.gpa);
}

/// Inflates one complete header block into `out` as `name: value` lines.
pub fn emit(self: *Decoder, out: *std.Io.Writer) void {
    const inf = self.inflater orelse return;
    var input = self.block.items;

    while (true) {
        var nv: h2.c.nghttp2_nv = undefined;
        var flags: c_int = 0;
        const consumed = h2.c.nghttp2_hd_inflate_hd2(
            inf,
            &nv,
            &flags,
            input.ptr,
            input.len,
            1, // in_final
        );
        if (consumed < 0) {
            break;
        }
        input = input[@intCast(consumed)..];

        if (flags & h2.c.NGHTTP2_HD_INFLATE_EMIT != 0) {
            out.print("{s}: {s}\n", .{
                nv.name[0..nv.namelen],
                nv.value[0..nv.valuelen],
            }) catch {};
        }
        if (flags & h2.c.NGHTTP2_HD_INFLATE_FINAL != 0) {
            break;
        }
        if (input.len == 0) {
            break;
        }
    }

    _ = h2.c.nghttp2_hd_inflate_end_headers(inf);
    self.block.clearRetainingCapacity();
}
