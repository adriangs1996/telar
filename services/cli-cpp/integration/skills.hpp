#pragma once

#include "files.hpp"
#include "integration_assets.hpp"
#include "telar_platform/read_regular_file.hpp"

namespace telar::runtime::cli::integration {

enum class Ownership { absent,
                       owned,
                       foreign };

inline std::string_view ownershipName(Ownership ownership) noexcept {
  switch (ownership) {
  case Ownership::absent:
    return "absent";
  case Ownership::owned:
    return "installed";
  case Ownership::foreign:
    return "foreign";
  }

  std::unreachable();
}

struct Skill {
  std::string_view name;
  std::string_view header;
  std::string_view marker;
  std::string_view text;
  bool legacy_header = false;
};

inline constexpr std::string_view telar_header = R"(---
name: telar
description: Drive telar, the terminal multiplexer and agent runtime this pane runs in. Use when the user asks about telar, about other panes, agents, workspaces or worktrees, about running or watching commands in terminals or on other machines, or when a command's output mentions telar. Teaches how to discover the installed telar's commands from its own help.
---
)";
inline constexpr std::string_view coordinator_header = R"(---
name: telar-coordinator
description: Delegate tasks to agents in their own Git worktrees and steer them through telar. Use when the user asks to implement, fix or build something in a separate worktree, or asks about, stops, redirects or reviews agents working in worktrees.
---
)";
inline constexpr auto skills = std::to_array<Skill>({
    {.name = "telar", .header = telar_header, .marker = "<!-- telar-integration: skill telar -->\n", .text = assets::telar_skill},
    {.name = "telar-coordinator", .header = coordinator_header, .marker = "<!-- telar-integration: skill telar-coordinator -->\n", .text = assets::coordinator_skill, .legacy_header = true},
});

template <Allocator Memory>
String<Memory> skillPath(Memory &memory, std::string_view root, const Skill &skill) {
  auto path = joinPath(memory, root, "skills");
  path = joinPath(memory, path, skill.name);
  return joinPath(memory, path, "SKILL.md");
}

template <Allocator Memory>
Ownership skillOwnership(const String<Memory> &path, const Skill &skill) noexcept {
  struct stat state{};
  if (::stat(path.c_str(), &state) != 0) {
    return errno == ENOENT ? Ownership::absent : Ownership::foreign;
  }

  std::array<char, 1024> buffer;
  const auto contents = readRegularFile(path, buffer);
  if (!contents) {
    return Ownership::foreign;
  }
  if (contents->contains(skill.marker) || (skill.legacy_header && contents->starts_with(skill.header) && contents->substr(skill.header.size()).starts_with('\n'))) {
    return Ownership::owned;
  }

  return Ownership::foreign;
}

template <Allocator Memory>
void installSkills(Memory &memory, std::string_view root) {
  for (const auto &skill : skills) {
    const auto path = skillPath(memory, root, skill);
    if (skillOwnership(path, skill) == Ownership::foreign) {
      std::printf("telar integration: skill %.*s at %s is not telar's; left untouched\n", static_cast<int>(skill.name.size()), skill.name.data(), path.c_str());
      continue;
    }

    String<Memory> contents{skill.header, AllocatorRef<char, Memory>{memory}};
    contents += skill.marker;
    contents += '\n';
    contents += skill.text;
    write(memory, path, contents, false);
    std::printf("telar integration: skill %.*s written to %s\n", static_cast<int>(skill.name.size()), skill.name.data(), path.c_str());
  }
}

template <Allocator Memory>
void reportSkills(Memory &memory, std::string_view root) {
  for (const auto &skill : skills) {
    const auto path = skillPath(memory, root, skill);
    std::printf("skill %.*s: %s at %s\n", static_cast<int>(skill.name.size()), skill.name.data(), ownershipName(skillOwnership(path, skill)).data(), path.c_str());
  }
}

template <Allocator Memory>
void removeSkills(Memory &memory, std::string_view root) noexcept {
  for (const auto &skill : skills) {
    try {
      const auto path = skillPath(memory, root, skill);
      if (skillOwnership(path, skill) == Ownership::owned) {
        ::unlink(path.c_str());
      }
    } catch (...) {
    }
  }
}

}
