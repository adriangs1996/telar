#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <cstddef>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.gui.application.sound_playback;

namespace {

using namespace telar;
using namespace telar::gui;
constexpr auto byte_bits = std::numeric_limits<unsigned char>::digits;

enum class Operation : unsigned char {
  clear,
  remember_history,
  forget_history,
  remember_layout,
  retain_layout,
  forget_layout,
  query,
};

template <std::unsigned_integral Value>
Value read() {
  Value value = 0;
  for (std::size_t index = 0; index < sizeof(Value); ++index) {
    const auto byte = std::getchar();
    if (byte == EOF) {
      throw std::runtime_error{"Truncated navigation input"};
    }

    value |= static_cast<Value>(static_cast<Value>(byte) << (index * byte_bits));
  }

  return value;
}

template <std::unsigned_integral Value>
void write(Value value) {
  for (std::size_t index = 0; index < sizeof(Value); ++index) {
    if (std::putchar(static_cast<unsigned char>(value >> (index * byte_bits))) == EOF) {
      throw std::runtime_error{"Navigation output failed"};
    }
  }
}

TabLocation readLocation() {
  const auto kind = read<std::uint8_t>();
  const auto identity = read<std::uint64_t>();

  return {.workspace = {.kind = kind == 0 ? WorkspaceLocation::Kind::workspace : WorkspaceLocation::Kind::worktree, .id = identity}, .tab_id = read<std::uint64_t>()};
}

void writeLocation(TabLocation location) {
  write<std::uint8_t>(location.workspace.kind == WorkspaceLocation::Kind::workspace ? 0 : 1);
  write(location.workspace.id);
  write(location.tab_id);
}

struct Input {
  std::uint64_t pane_id = 0;
  std::uint64_t focused_pane = 0;
  bool active = false;
  bool fullscreen = false;
  bool has_layout = false;
  std::array<ClientLayoutNode, PaneLayout::maximum_nodes> nodes{};
  std::size_t count = 0;

  void readFields() {
    pane_id = read<std::uint64_t>();
    focused_pane = read<std::uint64_t>();
    active = read<std::uint8_t>() != 0;
    fullscreen = read<std::uint8_t>() != 0;
    has_layout = read<std::uint8_t>() != 0;
    if (!has_layout) {
      return;
    }

    count = read<std::uint8_t>();
    if (count > nodes.size()) {
      throw std::length_error{"Navigation input tree exceeds capacity"};
    }

    for (auto &node : std::span{nodes}.first(count)) {
      if (read<std::uint8_t>() == 0) {
        node = ClientLayoutPane{read<std::uint64_t>()};
      } else {
        const auto axis = read<std::uint8_t>();
        node = ClientLayoutSplit{.axis = axis == 0 ? ClientLayoutAxis::horizontal : ClientLayoutAxis::vertical, .ratio = read<std::uint16_t>()};
      }
    }
  }

  [[nodiscard]] std::span<const ClientLayoutNode> tree() const noexcept {
    return std::span{nodes}.first(count);
  }
};

void writeTree(std::uint64_t focus, bool fullscreen, std::span<const ClientLayoutNode> nodes) {
  write(focus);
  write<std::uint8_t>(fullscreen ? 1 : 0);
  write(static_cast<std::uint8_t>(nodes.size()));
  for (const auto &node : nodes) {
    if (const auto *pane = std::get_if<ClientLayoutPane>(&node)) {
      write<std::uint8_t>(0);
      write(pane->pane_id);
    } else {
      const auto &split = std::get<ClientLayoutSplit>(node);
      write<std::uint8_t>(1);
      write<std::uint8_t>(split.axis == ClientLayoutAxis::horizontal ? 0 : 1);
      write(split.ratio);
    }
  }
}

void writeHistory(const NavigationHistory &history, WorkspaceLocation location) {
  const auto *bookmark = history.find(location);
  write<std::uint8_t>(bookmark != nullptr ? 1 : 0);
  if (bookmark == nullptr) {
    return;
  }

  writeLocation(bookmark->location);
  write(bookmark->pane_id);
  write<std::uint8_t>(bookmark->layout ? 1 : 0);
  if (bookmark->layout) {
    writeTree(bookmark->layout->focused_pane, bookmark->fullscreen, bookmark->layout->view());
  }
}

void writeSaved(std::optional<SavedLayouts::View> saved) {
  write<std::uint8_t>(saved ? 1 : 0);
  if (saved) {
    writeLocation(saved->location);
    write(saved->pane_id);
    write<std::uint8_t>(saved->workspace_active ? 1 : 0);
    writeTree(saved->focused_pane, saved->fullscreen, saved->nodes);
  }
}

bool apply(Operation operation, TabLocation location, NavigationHistory &history, SavedLayouts &layouts) {
  Input input;
  switch (operation) {
  case Operation::clear:
    history.clear();
    layouts.clear();
    break;
  case Operation::remember_history:
    input.readFields();
    history.remember({.location = location, .pane_id = input.pane_id, .layout = input.has_layout ? std::optional{NavigationHistory::Layout{input.tree(), input.focused_pane}} : std::nullopt, .fullscreen = input.fullscreen});
    break;
  case Operation::forget_history:
    history.forget(location.workspace);
    break;
  case Operation::remember_layout:
  case Operation::retain_layout: {
    input.readFields();
    const SavedLayouts::View saved{.location = location, .pane_id = input.pane_id, .focused_pane = input.focused_pane, .workspace_active = input.active, .fullscreen = input.fullscreen, .nodes = input.tree()};
    if (operation == Operation::remember_layout) {
      return layouts.remember(saved);
    }

    layouts.retain(saved);
    break;
  }
  case Operation::forget_layout:
    layouts.forget(location);
    break;
  case Operation::query:
    break;
  }

  return true;
}

}

int main() {
  try {
    NavigationHistory history;
    SavedLayouts layouts;
    for (int operation = std::getchar(); operation != EOF; operation = std::getchar()) {
      const auto location = readLocation();
      write<std::uint8_t>(apply(static_cast<Operation>(operation), location, history, layouts) ? 1 : 0);
      writeHistory(history, location.workspace);
      writeSaved(layouts.find(location));
      write(static_cast<std::uint16_t>(layouts.size()));
      write(static_cast<std::uint16_t>(layouts.nodeCount()));
      for (std::size_t index = 0; index < layouts.size(); ++index) {
        const auto saved = layouts.at(index);
        writeLocation(saved.location);
        writeSaved(layouts.find(saved.location));
      }
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
