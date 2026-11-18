#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include "telar_wire/protocol/pane_io.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>

import telar.testing;
import telar.testing.test_memory;
import telar.gui.tests.allocation_gate;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.gui.features.terminal.graphics;
import telar.gui.foundation.drawing;
import telar.gui.features.workbench;
import telar.gui.foundation.model;
import telar.gui.features.activity;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::workbench;
  using namespace telar::gui::features::activity;
  using namespace telar::gui::features::terminal::graphics;
  using namespace telar::gui::test;
  using namespace telar::gui::application::tests::session_fixture;

  constexpr Byte quarter_percent = 25;
  constexpr Byte half_percent = 50;
  constexpr float half_fraction = 0.5F;

  void selectionAndProgressPrecedence() {
    telar::testing::TestMemory adapter;
    telar::Memory& memory = adapter;
    GraphicsBudget budget;
    const TabLocation location{.workspace = {.id = 1}, .tab_id = 1};
    Tab tab{memory, location};

    tab.layout.add(1, ClientLayoutAxis::horizontal, 0);
    application::Pane pane{memory, 1, budget};

    pane.location = location;
    ds::Array agents{Agent{memory}, Agent{memory}};

    for (auto& agent : agents.viewMut()) {
      agent.location = location;
      agent.status = AgentStatus::working;
    }

    auto activity = TabActivity::derive(tab, pane.progress_state, std::span<const Agent<Memory>>{agents}, true);

    check(activity.kind == TabActivity::Kind::spinner && activity.width() == TabActivity::spinner_side, "working tabs must reserve the original spinner width");
    agents.atMut(0).status = AgentStatus::blocked;
    activity = TabActivity::derive(tab, pane.progress_state, std::span<const Agent<Memory>>{agents}, true);
    check(activity.kind == TabActivity::Kind::dot && activity.color == PaletteRole::yellow && activity.attention == PaletteRole::yellow, "a request for input must precede another pane's work");
    pane.progress_state = PaneProgressState::set;
    pane.progress_percent = quarter_percent;
    activity = TabActivity::derive(tab, pane.progress_state, std::span<const Agent<Memory>>{agents}, true);
    check(activity.kind == TabActivity::Kind::progress && activity.attention == PaletteRole::yellow, "active single-pane progress must retain independent hidden-tab attention");
    check(TabActivity::derive(tab, pane.progress_state, std::span<const Agent<Memory>>{agents}, false).kind == TabActivity::Kind::dot, "inactive tabs must keep agent status instead of terminal progress");
    tab.layout.add(2, ClientLayoutAxis::horizontal, 1);
    check(TabActivity::derive(tab, pane.progress_state, std::span<const Agent<Memory>>{agents}, true).kind == TabActivity::Kind::dot, "multi-pane tabs must not project one pane's progress as the tab's progress");
    for (auto& agent : agents.viewMut()) {
      agent.status = AgentStatus::ready;
    }

    check(TabActivity::derive(tab, pane.progress_state, std::span<const Agent<Memory>>{agents}, true).kind == TabActivity::Kind::none, "ready agents must reserve no trailing slot");
  }

  void transitionRetargetsAndAttachmentReplacement() {
    ProgressMotion motion;
    ProgressSample sample{.pane_id = 1, .attachment = 1, .state = PaneProgressState::set, .percent = 0};
    constexpr std::uint64_t start = 1'000'000'000;

    check(motion.sample(sample, start) == 0, "first observation must use the reported percentage");
    sample.percent = ProgressSample::maximum_percent;
    check(motion.sample(sample, start) == 0 && motion.deadline(start) == start + ProgressMotion::duration_ns, "a changed percentage must start from the visible value");
    const auto middle = start + (ProgressMotion::duration_ns / 2);
    constexpr float cubic_midpoint = 0.875F;

    check(motion.sample(sample, middle) == cubic_midpoint, "determinate fill must follow the original cubic easing");
    sample.percent = quarter_percent;
    check(motion.sample(sample, middle) == cubic_midpoint, "retargeting must not jump to the new report");
    ++sample.attachment;
    constexpr float replacement_fraction = 0.25F;

    check(motion.sample(sample, middle) == replacement_fraction && !motion.deadline(middle), "a replacement attachment must discard its predecessor's motion");
    sample.state = PaneProgressState::pause;
    sample.percent = half_percent;
    check(motion.sample(sample, middle) == half_fraction && !motion.deadline(middle), "paused reports must settle without polling");
    sample.state = PaneProgressState::remove;
    check(motion.sample(sample, middle) == 0 && !motion.deadline(middle), "removal must retire the visible interpolation");
    sample.state = PaneProgressState::set;
    check(motion.sample(sample, middle) == half_fraction && !motion.deadline(middle), "a new report after removal must start from its reported value");
  }

  void progressMessagesAreOwnedAndDeduplicated() {
    SystemAllocator upstream;
    BudgetAllocator budget{upstream, std::numeric_limits<std::size_t>::max()};
    AllocationGate gate{budget};
    telar::MemoryAdapter adapter{gate};
    telar::Memory& memory = adapter;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const auto allocations = budget.allocations();

    gate.permit(0);
    const PaneProgress report{.pane_id = 1, .state = PaneProgressState::set, .percent = quarter_percent};

    check(deliver(client, report) == application::Change::model, "progress must invalidate the projected tab");
    check(client.findPane(1)->progress_state == PaneProgressState::set && client.findPane(1)->progress_percent == quarter_percent, "the pane must retain the runtime-owned fact");
    check(deliver(client, report) == application::Change::none, "repeated progress must not rebuild the GUI");
    check(deliver(client, PaneProgress{.pane_id = 2, .state = PaneProgressState::indeterminate}) == application::Change::none, "progress must not create an unknown pane");
    check(deliver(client, PaneProgress{.pane_id = 1, .state = PaneProgressState::remove}) == application::Change::model && !client.findPane(1)->progress_percent, "removal must clear the retained percentage");
    check(budget.allocations() == allocations, "semantic progress updates must not allocate through the injected allocator");
  }

  void ringsRemainBounded() {
    constexpr std::size_t maximum_shapes = ProgressRing::segments + 2;
    std::size_t count = 0;
    const ProgressRing ring{.area = {.width = TabActivity::spinner_side, .height = TabActivity::spinner_side}, .color = Color::rgb(0x72b7ae), .fraction = 1};

    ring.visit([&](RoundedRectanglePaint paint) {
      check(paint.shape.size.x > 0 && paint.shape.size.y > 0, "ring quads must retain positive bounds");
      ++count;
    });

    check(count == maximum_shapes, "a full ring must emit one track and the bounded original arc points");
  }

  const telar::testing::Case case_selection_and_progress_precedence{"tab_activity.selection_and_progress_precedence", selectionAndProgressPrecedence};
  const telar::testing::Case case_transition_retargets_and_attachment_replacement{"tab_activity.transition_retargets_and_attachment_replacement", transitionRetargetsAndAttachmentReplacement};
  const telar::testing::Case case_progress_messages_are_owned_and_deduplicated{"tab_activity.progress_messages_are_owned_and_deduplicated", progressMessagesAreOwnedAndDeduplicated};
  const telar::testing::Case case_rings_remain_bounded{"tab_activity.rings_remain_bounded", ringsRemainBounded};

}
