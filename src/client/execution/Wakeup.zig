//! A notification only. Message storage and admission belong to the inbox.
context: usize = 0,
notify_fn: ?*const fn (usize) void = null,

/// Example: `wakeup.notify();`
pub fn notify(wakeup: @This()) void {
    if (wakeup.notify_fn) |call| {
        call(wakeup.context);
    }
}
