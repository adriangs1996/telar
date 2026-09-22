const Tab = @import("Tab.zig");
/// Iterates the open tabs in order without exposing the slot array.
const TabIterator = @This();

items: []?Tab,
index: usize = 0,

pub fn next(iterator: *TabIterator) ?*Tab {
    while (iterator.index < iterator.items.len) {
        const slot = &iterator.items[iterator.index];
        iterator.index += 1;
        if (slot.*) |*tab| {
            return tab;
        }
    }
    return null;
}
