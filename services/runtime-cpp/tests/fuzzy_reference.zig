const scoring = @import("lib/fuzzymatch/scoring.zig");
const Matrix = @import("lib/fuzzymatch/Matrix.zig");

var matrix: Matrix = undefined;

export fn fuzzy_score(path: [*]const u8, path_length: usize, query: [*]const u8, query_length: usize, positions: [*]u16) u64 {
    const path_text = path[0..path_length];
    const query_text = query[0..query_length];
    const ranked = scoring.score(path_text, query_text);
    const highlighted = scoring.match(&matrix, path_text, query_text, positions[0..query_length]);
    if (ranked != highlighted) {
        return @as(u64, 2) << 32;
    }

    return if (ranked) |value| (@as(u64, 1) << 32) | @as(u32, @bitCast(value)) else 0;
}
