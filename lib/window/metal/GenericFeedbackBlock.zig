const objc = @import("objc");

/// Captures must outlive GPU feedback. Only raw Objective-C ids are retained by block copies.
/// Example: `const Feedback = GenericFeedbackBlock.Type(Captures);`.
pub fn Type(comptime Captures: type) type {
    return objc.Block(Captures, .{objc.c.id}, void);
}
