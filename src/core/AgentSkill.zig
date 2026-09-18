name_offset: u16 = 0,
name_len: u16 = 0,
label_offset: u16 = 0,
label_len: u16 = 0,
description_offset: u16 = 0,
description_len: u16 = 0,
scope: Scope = .user,

pub const Scope = enum(u8) { user, repo, system, admin, plugin };

/// Example: `draw(skill.name(catalog));`
pub fn name(skill: @This(), catalog: *const @import("AgentSkills.zig")) []const u8 {
    return catalog.text[skill.name_offset..][0..skill.name_len];
}

/// Example: `draw(skill.label(catalog));`
pub fn label(skill: @This(), catalog: *const @import("AgentSkills.zig")) []const u8 {
    return catalog.text[skill.label_offset..][0..skill.label_len];
}

/// Example: `draw(skill.description(catalog));`
pub fn description(skill: @This(), catalog: *const @import("AgentSkills.zig")) []const u8 {
    return catalog.text[skill.description_offset..][0..skill.description_len];
}

/// Example: `draw(skill.scopeLabel());`
pub fn scopeLabel(skill: @This()) []const u8 {
    return switch (skill.scope) {
        .user => "Personal",
        .repo => "Project",
        .system => "System",
        .admin => "Admin",
        .plugin => "Plugin",
    };
}
