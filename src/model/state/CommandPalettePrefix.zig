pub const CommandPalettePrefix = enum(u8) {
    actions = '>',
    goto = '@',
    suggest = '?',
    machines = ':',

    /// The byte the prefix occupies in the prompt field.
    /// Example: `field.init(&.{prefix.byte()})`.
    pub fn byte(self: CommandPalettePrefix) u8 {
        return @intFromEnum(self);
    }

    /// Example: `const prefix = CommandPalettePrefix.parse(text[0]) orelse .goto;`.
    pub fn parse(value: u8) ?CommandPalettePrefix {
        return switch (value) {
            '>' => .actions,
            '@' => .goto,
            '?' => .suggest,
            ':' => .machines,
            else => null,
        };
    }
};
