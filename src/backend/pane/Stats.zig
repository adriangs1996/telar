const Stats = @This();

/// Rows whose cells were translated.
copied: u16 = 0,
/// Rows skipped because neither the emulator nor the caller marked them.
skipped: u16 = 0,
