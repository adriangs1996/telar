const client = @import("telar-client");

pub const Field = @FieldType(client.ChangeReviewComment, "body");

open: bool = false,
field: Field = .{},
previous: @FieldType(client.ChangeReviewModel, "search") = .{},
head: usize = 0,
tail: usize = 0,
visual: bool = false,
scroll: f32 = 0,
failure: ?[]const u8 = null,
