//! Names one command tab of a configuration generation's `CommandTabs`. A
//! reference from another generation, or to a recent row the table has
//! since cleared (`epoch`), names nothing.
const CommandTabRef = @This();

generation: u64,
/// 0 for a row the configuration fixed when it loaded; otherwise the
/// table's recent epoch when the row was kept.
epoch: u32 = 0,
id: u16,
