#pragma once

#include "../memory/allocator.hpp"
#include "../memory/fixed_text.hpp"
#include "../text/utf8.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <chrono>
#include <optional>

namespace telar::runtime {

template <Allocator Memory>
struct Tab {
  explicit Tab(Memory &memory, std::uint64_t identity, std::string_view name)
      : id(identity),
        label(name, AllocatorRef<char, Memory>{memory}),
        panes(AllocatorRef<std::uint64_t, Memory>{memory}) {
    panes.reserve(64);
  }

  std::uint64_t id;
  String<Memory> label;
  Vector<std::uint64_t, Memory> panes;
};

template <Allocator Memory>
class Workspace {
public:
  explicit Workspace(Memory &memory, std::uint64_t identity, std::string_view directory, std::string_view label)
      : id(identity),
        path(directory, AllocatorRef<char, Memory>{memory}),
        name(label, AllocatorRef<char, Memory>{memory}),
        tabs(AllocatorRef<Tab<Memory>, Memory>{memory}) {
    tabs.reserve(64);
  }

  Tab<Memory> *tab(std::uint64_t tab_id) noexcept {
    for (auto &entry : tabs) {
      if (entry.id == tab_id) {
        return &entry;
      }
    }

    return nullptr;
  }

  const Tab<Memory> *tab(std::uint64_t tab_id) const noexcept {
    return const_cast<Workspace *>(this)->tab(tab_id);
  }

  std::string_view displayName() const noexcept {
    if (!name.empty()) {
      return name;
    }

    std::string_view directory = path;
    while (directory.size() > 1 && directory.back() == '/') {
      directory.remove_suffix(1);
    }
    const auto basename = directory.substr(directory.rfind('/') + 1);
    return utf8Prefix(basename.empty() ? directory : basename, 256);
  }

  std::uint64_t id;
  String<Memory> path;
  String<Memory> name;
  Vector<Tab<Memory>, Memory> tabs;
  std::optional<std::uint64_t> geometry_client;
  FixedText<200> git_branch;
  std::chrono::steady_clock::time_point git_checked_at{};
  bool git_dirty = false;
  bool git_timed_out = false;
};

}
