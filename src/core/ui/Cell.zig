const Style = @import("Style.zig");
const std = @import("std");
const builtin = @import("builtin");
/// One screen position.
///
/// The payload is a grapheme cluster, not a codepoint: `é` may be two
/// codepoints and a flag emoji is two more, and all of them occupy one or two
/// columns as a unit. Storing bytes inline keeps `Cell` comparable with a plain
/// equality check, which the diff runs once per position per frame.
const Cell = @This();

/// Enough for a base character with a few combining marks. Longer clusters
/// - family emoji with several zero width joiners - are truncated, which
/// costs a rendering artefact rather than a corrupted grid.
pub const max_bytes = 16;

bytes: [max_bytes]u8 = [_]u8{' '} ++ [_]u8{0} ** (max_bytes - 1),
len: u8 = 1,
/// 0 marks the second half of a wide character. Nothing is emitted for it;
/// the terminal's own cursor advance covers it.
width: u8 = 1,
style: Style = .{},

pub fn text(c: *const Cell) []const u8 {
    return c.bytes[0..c.len];
}

/// The diff calls this once per position per frame, so it is the hottest
/// comparison in the renderer. It compares complete representations as one
/// 32-byte vector. Equal bytes imply equal values; cells built through
/// `Buffer.setCell`, the wire decoder or the defaults are canonical (bytes
/// after `len` keep their default, colors zero unused channels), so equal
/// values are also equal bytes on every hot path. A non-canonical cell can
/// only compare unequal, which costs a redundant repaint, never a stale one.
///
/// ```zig
/// if (next.eqlPublic(&previous)) continue;
/// ```
pub fn eqlPublic(a: *const Cell, b: *const Cell) bool {
    // Whole-cell loads through pointers: a byte view of the struct lets LLVM
    // reassemble lanes from fields it already loaded. The reduction differs
    // per target because each lowers the other poorly:
    //   AArch64: LDP, EOR, ORR, UMAXV (a byte-mask reduction becomes
    //            BIC/ZIP1/ADDV per 16 bytes);
    //   x86-64:  PCMPEQB, PAND, PMOVMSKB with SSE2 and VPXOR, VPTEST with
    //            AVX2 (a max reduction becomes PSHUFD/PMAXUB rounds).
    if (comptime builtin.cpu.arch.isAARCH64()) {
        const left: *align(1) const [2]Lanes = @ptrCast(a);
        const right: *align(1) const [2]Lanes = @ptrCast(b);
        return @reduce(.Max, (left[0] ^ right[0]) | (left[1] ^ right[1])) == 0;
    }

    const left: *align(1) const @Vector(@sizeOf(Cell), u8) = @ptrCast(a);
    const right: *align(1) const @Vector(@sizeOf(Cell), u8) = @ptrCast(b);
    return @reduce(.And, left.* == right.*);
}

const Lanes = @Vector(16, u8);

comptime {
    std.debug.assert(@sizeOf(Cell) == 32);
    std.debug.assert(std.meta.hasUniqueRepresentation(Cell));
}
