const Colors = @This();
const notifications = @import("telar-client").notifications;
surface0: [3]u8,
text: [3]u8,
subtext: [3]u8,
blue: [3]u8,
green: [3]u8,
yellow: [3]u8,
red: [3]u8,

pub fn level(colors: Colors, value: notifications.Level) [3]u8 {
    return switch (value) {
        .info => colors.blue,
        .success => colors.green,
        .warning => colors.yellow,
        .failure => colors.red,
    };
}
