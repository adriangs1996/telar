#pragma once

#include "../text/json.hpp"
#include <array>

namespace telar::runtime::plugins {

enum class Capability : std::uint8_t {
  workspace_read,
  workspace_write,
  process_spawn,
  network,
  clipboard_read,
  clipboard_write,
  notifications,
  history_read,
  history_write,
  proxy_tap,
  runtime_control
};

class Capabilities {
public:
  bool contains(Capability capability) const noexcept {
    return (bits_ & bit(capability)) != 0;
  }

  void insert(Capability capability) {
    if (contains(capability)) {
      throw std::invalid_argument{"Duplicate plugin capability"};
    }
    bits_ |= bit(capability);
  }

  static Capability parseName(std::string_view name) {
    const auto found = std::ranges::find(names_, name);
    if (found == names_.end()) {
      throw std::invalid_argument{"Unknown plugin capability"};
    }
    return static_cast<Capability>(found - names_.begin());
  }

  static std::string_view name(Capability capability) noexcept {
    return names_[static_cast<std::size_t>(capability)];
  }

  template <Allocator Memory>
  static Capabilities parse(Memory &memory, const JsonValue &value) {
    Capabilities result;
    String<Memory> text{AllocatorRef<char, Memory>{memory}};
    value.eachElement([&](const JsonValue &element) {
      element.string(text);
      result.insert(parseName(text));
    });
    return result;
  }

private:
  static constexpr std::uint16_t bit(Capability capability) noexcept {
    return std::uint16_t{1} << static_cast<unsigned>(capability);
  }

  static constexpr auto names_ = std::to_array<std::string_view>({
      "workspace.read",
      "workspace.write",
      "process.spawn",
      "network",
      "clipboard.read",
      "clipboard.write",
      "notifications",
      "history.read",
      "history.write",
      "proxy.tap",
      "runtime.control",
  });
  std::uint16_t bits_ = 0;
};

}
