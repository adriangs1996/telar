/// What a highlighted byte is, independent of any color: a theme maps each
/// role to a style.
pub const Role = enum(u8) { plain, keyword, string, number, comment, constant, builtin_constant, builtin, func, type, parameter, property, namespace, operator, punctuation };
