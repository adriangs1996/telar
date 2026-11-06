#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_base/memory/allocator.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include <charconv>
#include <string_view>
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>

#include "core/memory.hpp"


import telar.gui.application.sound_playback;
import telar.gui.core.unicode_scalar;

namespace {

using namespace telar;
using namespace telar::gui;

constexpr TabLocation fixture_location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 4}, .tab_id = 7};
constexpr std::uint64_t first_pane = 11;
constexpr std::uint64_t second_pane = 12;
constexpr std::uint16_t fixture_ratio = 3500;
constexpr std::uint16_t sidebar_columns = 53;
constexpr std::array<ClientLayoutNode, 3> fixture_nodes{
    ClientLayoutSplit{.axis = ClientLayoutAxis::vertical, .ratio = fixture_ratio},
    ClientLayoutPane{first_pane},
    ClientLayoutPane{second_pane},
};
constexpr ClientTabLayout fixture_tab{
    .location = fixture_location,
    .focused_pane = second_pane,
    .fullscreen = true,
    .workspace_active = true,
    .nodes = fixture_nodes,
};
constexpr std::array fixture_tabs{fixture_tab};
constexpr ClientLayoutSnapshot fixture_snapshot{
    .restored = true,
    .sidebar_visible = false,
    .sidebar_width = sidebar_columns,
    .workspace_list_collapsed = true,
    .active_tab = fixture_location,
    .tabs = fixture_tabs,
};
constexpr std::string_view zig_layout_token = "9f0100350001010004000000000000000700000000000000010000040000000000000007000000000000000c00000000000000010103000101ac0d000b00000000000000000c00000000000000";

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void referenceToken() {
  SystemAllocator system;
  constexpr std::size_t memory_capacity = 8192;
  BudgetAllocator memory{system, memory_capacity};
  {
    String<BudgetAllocator<SystemAllocator>> text{AllocatorRef<char, BudgetAllocator<SystemAllocator>>{memory}};
    require(LayoutToken::write(fixture_snapshot, text) == zig_layout_token, "export must match the token produced by Zig's original encoder byte for byte");
    const auto preset = LayoutToken::read(zig_layout_token);
    require(sameTab(preset.location, fixture_location), "import must preserve the token's persistent tab identity");
    require(preset.focused_pane == second_pane && preset.fullscreen, "import must preserve focus and fullscreen");
    require(preset.layout.nodes().size() == fixture_nodes.size(), "import must preserve every tree node");
    const auto *split = std::get_if<ClientLayoutSplit>(&preset.layout.nodes().front());
    require(split != nullptr && split->axis == ClientLayoutAxis::vertical && split->ratio == fixture_ratio, "import must preserve the split axis and fraction");
  }

  require(memory.liveBytes() == 0, "export storage must release its injected allocations");
}

void invalidTokens() {
  const std::array<std::string_view, 4> invalid{"", "0", "00", "gg"};
  for (const auto text : invalid) {
    bool rejected = false;
    try {
      LayoutToken::read(text);
    } catch (const EncodingError &) {
      rejected = true;
    }

    require(rejected, "empty, truncated and malformed tokens must be rejected");
  }

  const std::string oversized(LayoutToken::text_capacity + 1, '0');
  bool rejected = false;
  try {
    LayoutToken::read(oversized);
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected, "the routed command text capacity must bound imports");
}

void emptySnapshot() {
  SystemAllocator memory;
  String<SystemAllocator> text{AllocatorRef<char, SystemAllocator>{memory}};
  const ClientLayoutSnapshot bootstrap;
  LayoutToken::write(bootstrap, text);
  bool rejected = false;
  try {
    LayoutToken::read(text);
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected, "a valid bootstrap message without a restored tab cannot be applied as a token");
}

void displayIndicesSurviveFullscreenAndRemoval() {
  PaneLayout layout;
  layout.restore(fixture_nodes);
  constexpr CellRectangle area{.width = 600, .height = 400};
  const auto tiled = layout.arrange(area, {.gap = 0});
  require(tiled.size() == 2 && tiled.front().display_index == 1 && tiled.back().display_index == 2, "pane indices must follow tree display order");
  const auto fullscreen = layout.arrange(area, {.gap = 0}, second_pane);
  require(fullscreen.size() == 1 && fullscreen.front().display_index == 2, "fullscreen must retain the pane index from the complete layout");
  require(layout.remove(first_pane), "remove the first display pane");
  const auto remaining = layout.arrange(area, {.gap = 0});
  require(remaining.size() == 1 && remaining.front().display_index == 1, "indices must be recomputed after layout membership changes");
}

void fullCapacity() {
  PaneLayout layout;
  for (std::uint64_t pane_id = 1; pane_id <= PaneLayout::maximum_panes; ++pane_id) {
    require(layout.add(pane_id, ClientLayoutAxis::horizontal, pane_id - 1), "build the maximum-depth layout fixture");
  }

  const ClientTabLayout saved_tab{
      .location = fixture_location,
      .focused_pane = 1,
      .workspace_active = true,
      .nodes = layout.nodes(),
  };
  const std::array tabs{saved_tab};
  auto snapshot = fixture_snapshot;
  snapshot.tabs = tabs;
  SystemAllocator memory;
  String<SystemAllocator> text{AllocatorRef<char, SystemAllocator>{memory}};
  LayoutToken::write(snapshot, text);
  require(text.size() <= LayoutToken::text_capacity, "a complete tab must fit the CLI token capacity");
  const auto restored = LayoutToken::read(text);
  require(restored.layout.nodes().size() == PaneLayout::maximum_nodes, "the decoder must retain a maximum-depth split tree");
  for (std::uint64_t pane_id = 1; pane_id <= PaneLayout::maximum_panes; ++pane_id) {
    require(restored.layout.contains(pane_id), "all stable identities must survive a maximum-capacity token");
  }
}

}

int main() {
  try {
    referenceToken();
    invalidTokens();
    emptySnapshot();
    fullCapacity();
    displayIndicesSurviveFullscreenAndRemoval();
    std::cout << "gui-layout: passed\n";
  } catch (const std::exception &error) {
    std::cerr << "gui-layout: " << error.what() << '\n';

    return 1;
  }
}
