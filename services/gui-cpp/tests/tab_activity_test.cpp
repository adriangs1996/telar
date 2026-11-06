#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "allocation_gate.hpp"
#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <cstdint>
#include <limits>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <utility>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include "../terminal/screen.hpp"
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <stdexcept>
#include <charconv>
#include <cstring>
#include <system_error>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "../terminal/cell_position.hpp"
#include <bit>
#include <tuple>
#include <cmath>
#include "../input/wheel_accumulator.hpp"
#include "telar_base/memory/allocator.hpp"
#include <memory>
#include "assertions.hpp"
#include <numbers>
#include "session_fixture.hpp"
#include <iostream>

#include "core/memory.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.application.session;
import telar.gui.core.metrics;
import telar.gui.graphics.placeholder;
import telar.gui.graphics.texture_cache;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.activity_order;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

constexpr Byte quarter_percent = 25;
constexpr Byte half_percent = 50;
constexpr float half_fraction = 0.5F;

void selectionAndProgressPrecedence() {
  SystemAllocator memory;
  GraphicsBudget budget;
  const TabLocation location{.workspace = {.id = 1}, .tab_id = 1};
  Tab tab{memory, location};
  tab.layout.add(1, ClientLayoutAxis::horizontal, 0);
  Pane pane{memory, 1, budget};
  pane.location = location;
  std::array agents{Agent{memory}, Agent{memory}};
  for (auto &agent : agents) {
    agent.location = location;
    agent.status = AgentStatus::working;
  }

  auto activity = TabActivity::derive(tab, &pane, std::span<const Agent<SystemAllocator>>{agents}, true);
  require(activity.kind == TabActivity::Kind::spinner && activity.width() == TabActivity::spinner_side, "working tabs must reserve the original spinner width");
  agents.front().status = AgentStatus::blocked;
  activity = TabActivity::derive(tab, &pane, std::span<const Agent<SystemAllocator>>{agents}, true);
  require(activity.kind == TabActivity::Kind::dot && activity.color == PaletteRole::yellow && activity.attention == PaletteRole::yellow, "a request for input must precede another pane's work");
  pane.progress_state = PaneProgressState::set;
  pane.progress_percent = quarter_percent;
  activity = TabActivity::derive(tab, &pane, std::span<const Agent<SystemAllocator>>{agents}, true);
  require(activity.kind == TabActivity::Kind::progress && activity.attention == PaletteRole::yellow, "active single-pane progress must retain independent hidden-tab attention");
  require(TabActivity::derive(tab, &pane, std::span<const Agent<SystemAllocator>>{agents}, false).kind == TabActivity::Kind::dot, "inactive tabs must keep agent status instead of terminal progress");
  tab.layout.add(2, ClientLayoutAxis::horizontal, 1);
  require(TabActivity::derive(tab, &pane, std::span<const Agent<SystemAllocator>>{agents}, true).kind == TabActivity::Kind::dot, "multi-pane tabs must not project one pane's progress as the tab's progress");
  for (auto &agent : agents) {
    agent.status = AgentStatus::ready;
  }

  require(TabActivity::derive(tab, &pane, std::span<const Agent<SystemAllocator>>{agents}, true).kind == TabActivity::Kind::none, "ready agents must reserve no trailing slot");
}

void transitionRetargetsAndAttachmentReplacement() {
  ProgressMotion motion;
  ProgressSample sample{.pane_id = 1, .attachment = 1, .state = PaneProgressState::set, .percent = 0};
  constexpr std::uint64_t start = 1'000'000'000;
  require(motion.sample(sample, start) == 0, "first observation must use the reported percentage");
  sample.percent = ProgressSample::maximum_percent;
  require(motion.sample(sample, start) == 0 && motion.deadline(start) == start + ProgressMotion::duration_ns, "a changed percentage must start from the visible value");
  const auto middle = start + (ProgressMotion::duration_ns / 2);
  constexpr float cubic_midpoint = 0.875F;
  require(motion.sample(sample, middle) == cubic_midpoint, "determinate fill must follow the original cubic easing");
  sample.percent = quarter_percent;
  require(motion.sample(sample, middle) == cubic_midpoint, "retargeting must not jump to the new report");
  ++sample.attachment;
  constexpr float replacement_fraction = 0.25F;
  require(motion.sample(sample, middle) == replacement_fraction && !motion.deadline(middle), "a replacement attachment must discard its predecessor's motion");
  sample.state = PaneProgressState::pause;
  sample.percent = half_percent;
  require(motion.sample(sample, middle) == half_fraction && !motion.deadline(middle), "paused reports must settle without polling");
  sample.state = PaneProgressState::remove;
  require(motion.sample(sample, middle) == 0 && !motion.deadline(middle), "removal must retire the visible interpolation");
  sample.state = PaneProgressState::set;
  require(motion.sample(sample, middle) == half_fraction && !motion.deadline(middle), "a new report after removal must start from its reported value");
}

void progressMessagesAreOwnedAndDeduplicated() {
  SystemAllocator upstream;
  BudgetAllocator budget{upstream, std::numeric_limits<std::size_t>::max()};
  AllocationGate memory{budget};
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const auto allocations = budget.allocations();
  memory.permit(0);
  const PaneProgress report{.pane_id = 1, .state = PaneProgressState::set, .percent = quarter_percent};
  require(deliver(client, report) == Change::model, "progress must invalidate the projected tab");
  require(client.findPane(1)->progress_state == PaneProgressState::set && client.findPane(1)->progress_percent == quarter_percent, "the pane must retain the runtime-owned fact");
  require(deliver(client, report) == Change::none, "repeated progress must not rebuild the GUI");
  require(deliver(client, PaneProgress{.pane_id = 2, .state = PaneProgressState::indeterminate}) == Change::none, "progress must not create an unknown pane");
  require(deliver(client, PaneProgress{.pane_id = 1, .state = PaneProgressState::remove}) == Change::model && !client.findPane(1)->progress_percent, "removal must clear the retained percentage");
  require(budget.allocations() == allocations, "semantic progress updates must not allocate through the injected allocator");
}

void ringsRemainBounded() {
  constexpr std::size_t maximum_shapes = ProgressRing::segments + 2;
  std::size_t count = 0;
  const ProgressRing ring{.area = {.width = TabActivity::spinner_side, .height = TabActivity::spinner_side}, .color = Color::rgb(0x72b7ae), .fraction = 1};
  ring.visit([&](RoundedRectanglePaint paint) {
    require(paint.shape.size.x > 0 && paint.shape.size.y > 0, "ring quads must retain positive bounds");
    ++count;
  });
  require(count == maximum_shapes, "a full ring must emit one track and the bounded original arc points");
}

}

int main() try {
  selectionAndProgressPrecedence();
  transitionRetargetsAndAttachmentReplacement();
  progressMessagesAreOwnedAndDeduplicated();
  ringsRemainBounded();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
