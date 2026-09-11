const Windows = @This();

pub extern "user32" fn MessageBeep(message_type: u32) callconv(.winapi) i32;
