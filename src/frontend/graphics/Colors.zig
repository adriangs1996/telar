const data = @import("model");
const Colors = @This();

surface0: [3]u8,
text: [3]u8,
subtext: [3]u8,
blue: [3]u8,
green: [3]u8,
yellow: [3]u8,
red: [3]u8,

pub fn level(self: Colors, value: data.NotificationLevel) [3]u8 {
    return switch (value) {
        .info => self.blue,
        .success => self.green,
        .warning => self.yellow,
        .failure => self.red,
    };
}
