//! The source pixels one destination index covers on one axis of a box
//! filter: `[first, end)` with the partial coverage of both ends.
const FilterSpan = @This();

first: u32,
end: u32,
/// Coverage of `first` and of `end - 1`; interior pixels weigh one.
lead: f32,
trail: f32,

/// The weight of source index `index` inside the span.
/// Example: `const w = span.weight(x);`
pub fn weight(self: FilterSpan, index: u32) f32 {
    if (self.end == self.first + 1) {
        return self.lead + self.trail - 1;
    }

    if (index == self.first) {
        return self.lead;
    }

    return if (index == self.end - 1) self.trail else 1;
}

/// The span destination `index` of `side` covers over `source_extent`.
/// Example: `const columns = FilterSpan.of(column, side, source.width);`
pub fn of(index: u32, side: u32, source_extent: u32) FilterSpan {
    const scale = @as(f32, @floatFromInt(source_extent)) / @as(f32, @floatFromInt(side));
    const start = @as(f32, @floatFromInt(index)) * scale;
    const stop = @min(@as(f32, @floatFromInt(source_extent)), start + scale);
    const first: u32 = @intFromFloat(@floor(start));
    const last: u32 = @min(source_extent - 1, @as(u32, @intFromFloat(@ceil(stop))) -| 1);
    return .{
        .first = first,
        .end = last + 1,
        .lead = @as(f32, @floatFromInt(first + 1)) - start,
        .trail = stop - @as(f32, @floatFromInt(last)),
    };
}
