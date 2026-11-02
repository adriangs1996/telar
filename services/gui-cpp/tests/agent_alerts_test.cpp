#include "application/agent_alerts.hpp"
#include "application/agent_replica.hpp"
#include "application/agent_status_change.hpp"
#include "application/notification_center.hpp"
#include "application/notification_item.hpp"
#include "assertions.hpp"
#include "core/memory.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <string>
#include <string_view>

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::require;

constexpr std::uint64_t now_ns = 1'000'000'000;

void individualAlertsOwnMetadataAndDurations() {
  constexpr std::array statuses{AgentStatus::unknown, AgentStatus::working, AgentStatus::ready, AgentStatus::blocked, AgentStatus::done, AgentStatus::failed};
  for (const auto status : statuses) {
    const AgentStatusChange change{.pane_id = 42, .pane_index = 7, .current = status};
    AgentAlerts::Message message;
    const auto input = AgentAlerts::input(change, "Custom agent", message);
    require(input.has_value() == AgentAlerts::alertable(change), "only blocked, done and failed transitions must alert");
    if (!input) {
      continue;
    }

    require(input->target.kind == NotificationTarget::Kind::pane && input->target.id == change.pane_id, "an individual alert must navigate to the exact pane identity");
    require(input->link.empty(), "agent alerts must not invent external links");
    if (status == AgentStatus::blocked) {
      require(input->title == "Agent needs input" && input->message == "Custom agent in pane 7 is waiting for input" && input->level == NotificationLevel::warning, "blocked alerts must retain the original copy and severity");
    } else if (status == AgentStatus::done) {
      require(input->title == "Agent done" && input->message == "Custom agent in pane 7 is done" && input->level == NotificationLevel::success, "done alerts must retain the original copy and severity");
    } else {
      require(input->title == "Agent failed" && input->message == "Custom agent in pane 7 is failed" && input->level == NotificationLevel::failure, "failed alerts must retain the original copy and severity");
    }

    const auto expected_duration = status == AgentStatus::failed ? AgentAlerts::failed_duration_ns : NotificationInput::default_duration_ns;
    require(input->duration_ns == expected_duration, "failed agents must have the longer display duration");
  }

  const std::string oversized_label(AgentAlerts::message_capacity, 'x');
  AgentAlerts::Message message;
  const auto fallback = AgentAlerts::input({.current = AgentStatus::blocked}, oversized_label, message);
  require(fallback && fallback->message == "Agent status changed", "oversized labels must use the complete original fallback");
}

void oversizedBatchesFoldWithoutEvictingTheirOwnAlerts() {
  std::array<AgentStatusChange, AgentReplica<SystemAllocator>::capacity> changes;
  for (std::size_t index = 0; index < changes.size(); ++index) {
    changes[index] = {.pane_id = index + 1, .pane_index = static_cast<std::uint16_t>(index + 1), .current = AgentStatus::blocked};
  }

  changes[0].current = AgentStatus::working;
  changes[4].current = AgentStatus::done;
  constexpr std::size_t failed_index = 5;
  changes[failed_index].current = AgentStatus::failed;
  NotificationCenter center;
  const auto count = AgentAlerts::publish(changes, [](const AgentStatusChange &) {
    return std::string_view{"Agent"};
  },
                                          [&](NotificationInput input) {
                                            center.push(now_ns, input);
                                          });
  require(count == NotificationCenter::capacity && center.items().size() == count, "a large batch must publish exactly one center capacity");
  const auto &summary = center.items().front();
  require(summary.title.view() == "More agents changed" && summary.message.view() == "60 more agents: 58 waiting for input, 1 done, 1 failed", "folded counts must cover every omitted agent in the original status order");
  require(summary.level == NotificationLevel::failure && summary.expires_at_ns == now_ns + NotificationItem::transition_duration_ns + AgentAlerts::failed_duration_ns, "the summary must retain its strongest severity and duration");
  require(summary.target.kind == NotificationTarget::Kind::none && !summary.clickable(), "a folded alert must not select an arbitrary agent");
  require(center.items()[1].target.id == 4 && center.items()[2].target.id == 3 && center.items()[3].target.id == 2, "individuals must retain source order and the center must show newest first");
}

void exactCapacityKeepsAllIndividuals() {
  std::array<AgentStatusChange, NotificationCenter::capacity> changes;
  for (std::size_t index = 0; index < changes.size(); ++index) {
    changes[index] = {.pane_id = index + 1, .current = AgentStatus::done};
  }

  NotificationCenter center;
  const auto published = AgentAlerts::publish(changes, [](const AgentStatusChange &) {
    return std::string_view{"Agent"};
  },
                                              [&](NotificationInput input) {
                                                center.push(now_ns, input);
                                              });
  require(published == changes.size(), "a batch at capacity must not fold prematurely");
  for (const auto &item : center.items()) {
    require(item.title.view() == "Agent done" && item.target.kind == NotificationTarget::Kind::pane, "each agent must retain its individual actionable card");
  }
}

}

int main() try {
  individualAlertsOwnMetadataAndDurations();
  oversizedBatchesFoldWithoutEvictingTheirOwnAlerts();
  exactCapacityKeepsAllIndividuals();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
