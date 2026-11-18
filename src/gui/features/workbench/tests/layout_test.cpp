#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>

import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.gui.features.workbench;
import telar.wire.layout;
import telar.wire.vocabulary;
import telar.gui.foundation.model;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::workbench;

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
  constexpr std::string_view reference_layout_token = "9f0100350001010004000000000000000700000000000000010000040000000000000007000000000000000c00000000000000010103000101ac0d000b00000000000000000c00000000000000";

  void referenceToken() {
    SystemAllocator system;
    constexpr std::size_t memory_capacity = 8192;
    BudgetAllocator allocator{system, memory_capacity};
    telar::MemoryAdapter adapter{allocator};
    telar::Memory& memory = adapter;

    {
      String<telar::Memory> text{AllocatorRef<char, telar::Memory>{memory}};

      check(LayoutToken::write(fixture_snapshot, text) == reference_layout_token, "export must match the reference token byte for byte");
      const auto preset = LayoutToken::read(reference_layout_token);

      check(sameTab(preset.location, fixture_location), "import must preserve the token's persistent tab identity");
      check(preset.focused_pane == second_pane && preset.fullscreen, "import must preserve focus and fullscreen");
      check(preset.layout.nodes().size() == fixture_nodes.size(), "import must preserve every tree node");
      const auto* split = std::get_if<ClientLayoutSplit>(&preset.layout.nodes().front());

      check(split != nullptr && split->axis == ClientLayoutAxis::vertical && split->ratio == fixture_ratio, "import must preserve the split axis and fraction");
    }

    check(allocator.liveBytes() == 0, "export storage must release its injected allocations");
  }

  void invalidTokens() {
    const std::array<std::string_view, 4> invalid{"", "0", "00", "gg"};

    for (const auto text : invalid) {
      bool rejected = false;

      try {
        LayoutToken::read(text);
      } catch (const EncodingError&) {
        rejected = true;
      }

      check(rejected, "empty, truncated and malformed tokens must be rejected");
    }

    const std::string oversized(LayoutToken::text_capacity + 1, '0');
    bool rejected = false;

    try {
      LayoutToken::read(oversized);
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected, "the routed command text capacity must bound imports");
  }

  void emptySnapshot() {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::ConcurrentMemory& memory = adapter;
    String<telar::ConcurrentMemory> text{AllocatorRef<char, telar::ConcurrentMemory>{memory}};
    const ClientLayoutSnapshot bootstrap;

    LayoutToken::write(bootstrap, text);
    bool rejected = false;

    try {
      LayoutToken::read(text);
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected, "a valid bootstrap message without a restored tab cannot be applied as a token");
  }

  void displayIndicesSurviveFullscreenAndRemoval() {
    PaneLayout layout;

    layout.restore(fixture_nodes);
    constexpr CellRectangle area{.width = 600, .height = 400};
    const auto tiled = layout.arrange(area, {.gap = 0});

    check(tiled.size() == 2 && tiled.front().display_index == 1 && tiled.back().display_index == 2, "pane indices must follow tree display order");
    const auto fullscreen = layout.arrange(area, {.gap = 0}, second_pane);

    check(fullscreen.size() == 1 && fullscreen.front().display_index == 2, "fullscreen must retain the pane index from the complete layout");
    check(layout.remove(first_pane), "remove the first display pane");
    const auto remaining = layout.arrange(area, {.gap = 0});

    check(remaining.size() == 1 && remaining.front().display_index == 1, "indices must be recomputed after layout membership changes");
  }

  void fullCapacity() {
    PaneLayout layout;

    for (std::uint64_t pane_id = 1; pane_id <= PaneLayout::maximum_panes; ++pane_id) {
      check(layout.add(pane_id, ClientLayoutAxis::horizontal, pane_id - 1), "build the maximum-depth layout fixture");
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
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::ConcurrentMemory& memory = adapter;
    String<telar::ConcurrentMemory> text{AllocatorRef<char, telar::ConcurrentMemory>{memory}};

    LayoutToken::write(snapshot, text);
    check(text.size() <= LayoutToken::text_capacity, "a complete tab must fit the CLI token capacity");
    const auto restored = LayoutToken::read(text);

    check(restored.layout.nodes().size() == PaneLayout::maximum_nodes, "the decoder must retain a maximum-depth split tree");
    for (std::uint64_t pane_id = 1; pane_id <= PaneLayout::maximum_panes; ++pane_id) {
      check(restored.layout.contains(pane_id), "all stable identities must survive a maximum-capacity token");
    }
  }

  const telar::testing::Case case_reference_token{"layout.reference_token", referenceToken};
  const telar::testing::Case case_invalid_tokens{"layout.invalid_tokens", invalidTokens};
  const telar::testing::Case case_empty_snapshot{"layout.empty_snapshot", emptySnapshot};
  const telar::testing::Case case_full_capacity{"layout.full_capacity", fullCapacity};
  const telar::testing::Case case_display_indices_survive_fullscreen_and_removal{"layout.display_indices_survive_fullscreen_and_removal", displayIndicesSurviveFullscreenAndRemoval};

}
