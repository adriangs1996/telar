//! Which capture bounds cut a half short. Each cause is the first bound a
//! fragment met, so the owner can name the bound to raise.
const Truncation = @This();

/// A head or a body reached `max_part_bytes`.
part: bool = false,
/// The half reached its share of `max_exchange_bytes`.
exchange: bool = false,
/// Every capture together reached `max_total_bytes`.
total: bool = false,

/// Whether any bound cut the half short.
///
/// ```zig
/// if (half.truncation.any()) count(half.truncation);
/// ```
pub fn any(self: Truncation) bool {
    return self.part or self.exchange or self.total;
}
