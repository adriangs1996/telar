#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <variant>

import telar.testing;
import telar.gui.application;
import telar.gui.foundation.model;
import telar.gui.features.notifications;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::notifications;

  constexpr std::uint64_t now_ns = 1'000'000'000;

  void individualAlertsOwnMetadataAndDurations() {
    constexpr ds::Array statuses{AgentStatus::unknown, AgentStatus::working, AgentStatus::ready, AgentStatus::blocked, AgentStatus::done, AgentStatus::failed};

    for (const auto status : statuses) {
      const AgentStatusChange change{.pane_id = 42, .pane_index = 7, .current = status};
      AgentAlerts::Message message;
      const auto input = AgentAlerts::input(change, "Custom agent", message);

      check(input.hasValue() == AgentAlerts::alertable(change), "only blocked, done and failed transitions must alert");
      if (!input) {
        continue;
      }

      check(input->target.kind == NotificationTarget::Kind::pane && input->target.id == change.pane_id, "an individual alert must navigate to the exact pane identity");
      check(input->link.empty(), "agent alerts must not invent external links");
      if (status == AgentStatus::blocked) {
        check(input->title == "Agent needs input" && input->message == "Custom agent in pane 7 is waiting for input" && input->level == NotificationLevel::warning, "blocked alerts must retain the original copy and severity");
      } else if (status == AgentStatus::done) {
        check(input->title == "Agent done" && input->message == "Custom agent in pane 7 is done" && input->level == NotificationLevel::success, "done alerts must retain the original copy and severity");
      } else {
        check(input->title == "Agent failed" && input->message == "Custom agent in pane 7 is failed" && input->level == NotificationLevel::failure, "failed alerts must retain the original copy and severity");
      }

      const auto expected_duration = status == AgentStatus::failed ? AgentAlerts::failed_duration_ns : NotificationInput::default_duration_ns;

      check(input->duration_ns == expected_duration, "failed agents must have the longer display duration");
    }

    const std::string oversized_label(AgentAlerts::message_capacity, 'x');
    AgentAlerts::Message message;
    const auto fallback = AgentAlerts::input({.current = AgentStatus::blocked}, oversized_label, message);

    check(fallback && fallback->message == "Agent status changed", "oversized labels must use the complete original fallback");
  }

  void oversizedBatchesFoldWithoutEvictingTheirOwnAlerts() {
    ds::Array<AgentStatusChange, AgentReplica<telar::ConcurrentMemory>::capacity> changes;

    for (std::size_t index = 0; index < changes.size(); ++index) {
      changes.atMut(index) = {.pane_id = index + 1, .pane_index = static_cast<std::uint16_t>(index + 1), .current = AgentStatus::blocked};
    }

    changes.atMut(0).current = AgentStatus::working;
    changes.atMut(4).current = AgentStatus::done;
    constexpr std::size_t failed_index = 5;

    changes.atMut(failed_index).current = AgentStatus::failed;
    NotificationCenter center;
    const auto count = AgentAlerts::publish(changes, [](const AgentStatusChange&) {
      return std::string_view{"Agent"};
    },
        [&](NotificationInput input) {
          center.push(now_ns, input);
        });

    check(count == NotificationCenter::capacity && center.items().size() == count, "a large batch must publish exactly one center capacity");
    const auto& summary = center.items().front();

    check(summary.title.view() == "More agents changed" && summary.message.view() == "60 more agents: 58 waiting for input, 1 done, 1 failed", "folded counts must cover every omitted agent in the original status order");
    check(summary.level == NotificationLevel::failure && summary.expires_at_ns == now_ns + NotificationItem::transition_duration_ns + AgentAlerts::failed_duration_ns, "the summary must retain its strongest severity and duration");
    check(summary.target.kind == NotificationTarget::Kind::none && !summary.clickable(), "a folded alert must not select an arbitrary agent");
    check(center.items()[1].target.id == 4 && center.items()[2].target.id == 3 && center.items()[3].target.id == 2, "individuals must retain source order and the center must show newest first");
  }

  void exactCapacityKeepsAllIndividuals() {
    ds::Array<AgentStatusChange, NotificationCenter::capacity> changes;

    for (std::size_t index = 0; index < changes.size(); ++index) {
      changes.atMut(index) = {.pane_id = index + 1, .current = AgentStatus::done};
    }

    NotificationCenter center;
    const auto published = AgentAlerts::publish(changes, [](const AgentStatusChange&) {
      return std::string_view{"Agent"};
    },
        [&](NotificationInput input) {
          center.push(now_ns, input);
        });

    check(published == changes.size(), "a batch at capacity must not fold prematurely");
    for (const auto& item : center.items()) {
      check(item.title.view() == "Agent done" && item.target.kind == NotificationTarget::Kind::pane, "each agent must retain its individual actionable card");
    }
  }

  const telar::testing::Case case_individual_alerts_own_metadata_and_durations{"agent_alerts.individual_alerts_own_metadata_and_durations", individualAlertsOwnMetadataAndDurations};
  const telar::testing::Case case_oversized_batches_fold_without_evicting_their_own_alerts{"agent_alerts.oversized_batches_fold_without_evicting_their_own_alerts", oversizedBatchesFoldWithoutEvictingTheirOwnAlerts};
  const telar::testing::Case case_exact_capacity_keeps_all_individuals{"agent_alerts.exact_capacity_keeps_all_individuals", exactCapacityKeepsAllIndividuals};

}
