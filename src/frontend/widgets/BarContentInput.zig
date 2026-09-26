//! One configured slot to fit and draw in cells.
const data = @import("model");
const BarContentInput = @This();

content: *const data.Content,
alignment: data.bar_values.Alignment = .left,
facts: *const data.BarFacts,
position: data.bar_values.Position,
