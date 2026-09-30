//! One Kitty graphics command a `KittyCommandScanner` saw end. The slices
//! borrow the scanner and stay valid until its next call.
const KittyCommand = @This();

/// Index just past the command's terminator in the slice that ended it.
end: usize,
/// Control data between `ESC _ G` and `;`, cut at the scanner's capacity.
control: []const u8,
/// The first payload bytes, still encoded as the child sent them.
payload: []const u8,
/// The control data did not fit and is incomplete.
truncated: bool,
