#pragma once

#include "../agents/agent.hpp"
#include "../model/runtime_model.hpp"
#include "telar_client/request_error.hpp"

namespace telar::runtime {

enum class ReportDecision {
  accepted,
  deferred,
  rejected
};

template <typename Message>
std::optional<ReporterIdentity> reporterOf(const AgentManifests &manifests, const Message &message) noexcept {
  if constexpr (std::same_as<Message, ReportAgent> || std::same_as<Message, ReportAgentTitle> || std::same_as<Message, ReportAgentProgress>) {
    return ReporterIdentity{message.pane_id, message.pane_generation, message.provider};
  } else if constexpr (std::same_as<Message, ReportAgentCommand>) {
    return ReporterIdentity{message.pane_id, message.pane_generation, manifests.named(message.provider)};
  } else {
    return std::nullopt;
  }
}

template <typename Agents>
concept ReporterAgents = requires(const Agents &agents, std::uint64_t pane, std::uint64_t generation) {
  { agents.find(pane, generation) } -> std::convertible_to<const Agent *>;
};

template <Allocator Memory, ReporterAgents Agents>
class DeferredReports {
public:
  explicit DeferredReports(RuntimeModel<Memory> &model, const Agents &agents) noexcept
      : model_(model),
        agents_(agents) {}

  ReportDecision evaluate(ClientSession<Memory> &client, ReporterIdentity reporter, std::span<const Byte> payload) {
    if (reporter.provider == AgentProvider::unknown) {
      return ReportDecision::accepted;
    }

    auto *pane = model_.panes.find(reporter.pane);
    if (pane == nullptr || pane->generation != reporter.generation || pane->exit_status) {
      throw RequestError{FailureCode::pane_not_found, "Pane not found"};
    }
    if (client.verified_pane != pane->id || client.verified_generation != pane->generation) {
      throw RequestError{FailureCode::foreign_process, "The report does not come from this pane's agent"};
    }
    if (accepts(reporter)) {
      return ReportDecision::accepted;
    }

    auto &report = client.deferred_report;
    const auto rejection = reportingRejection(client, *pane);
    if (report.answering) {
      if (report.answer_rechecked && rejection) {
        pane->rejected_reporter = rejection;
      }
      return ReportDecision::rejected;
    }
    if (rejection && pane->rejected_reporter == rejection) {
      return ReportDecision::rejected;
    }

    report.payload.assign(payload.begin(), payload.end());
    report.reporter = reporter;
    report.required_recheck = pane->process_rechecks + (pane->process_recheck_running ? 2 : 1);
    report.observed = ObservationTime::now();
    report.sequence = ++sequence_;
    report.pending = true;
    client.connection.read_paused = true;
    pane->process_recheck_requested = true;
    ++pending_;
    return ReportDecision::deferred;
  }

  void cancel(ClientSession<Memory> &client) noexcept {
    if (client.deferred_report.pending) {
      client.deferred_report.pending = false;
      client.connection.read_paused = false;
      --pending_;
    }
  }

  template <typename Consumer>
  void answerDue(ObservationTime now, Consumer &&consume) {
    if (pending_ == 0) {
      return;
    }

    std::array<ClientSession<Memory> *, 32> due;
    std::size_t count = 0;
    for (auto *client : model_.clients.items()) {
      if (client == nullptr || !client->deferred_report.pending) {
        continue;
      }

      auto &report = client->deferred_report;
      const auto *pane = model_.panes.find(report.reporter.pane);
      const bool gone = pane == nullptr || pane->generation != report.reporter.generation || pane->exit_status;
      const bool timed_out = now.nanoseconds - report.observed.nanoseconds >= report_timeout.count();
      const bool rechecked = !gone && report.rechecked(pane->process_rechecks);
      const bool accepted = !gone && accepts(report.reporter);
      if (gone || timed_out || rechecked || accepted) {
        report.answer_rechecked = rechecked || accepted;
        due[count++] = client;
      }
    }

    auto ordered = std::span{due}.first(count);
    std::ranges::sort(ordered, [](const auto *left, const auto *right) {
      return std::bit_cast<std::int64_t>(left->deferred_report.sequence - right->deferred_report.sequence) < 0;
    });
    for (auto *client : ordered) {
      auto &report = client->deferred_report;
      cancel(*client);
      report.answering = true;
      client->connection.read_paused = false;
      try {
        if (!client->connection.closing) {
          consume(*client, std::span<const Byte>{report.payload});
        }
      } catch (...) {
        client->connection.closeImmediately();
      }
      report.answering = false;
      report.payload.clear();
    }
  }

private:
  bool accepts(ReporterIdentity reporter) const noexcept {
    const auto *agent = agents_.find(reporter.pane, reporter.generation);
    return agent == nullptr || agent->evidence.accepts(reporter.provider);
  }

  std::optional<RejectedReporter> reportingRejection(const ClientSession<Memory> &client, const Pane<Memory> &pane) const noexcept {
    const auto *agent = agents_.find(pane.id, pane.generation);
    if (agent == nullptr || !agent->agent_identity || !agent->process_identity) {
      return std::nullopt;
    }

    const auto group = agent->process_identity->pid;
    const auto member = agent->agent_identity->pid;
    const auto root = pane.process->processId();
    const auto lineage = client.verified_lineage.ancestors();
    for (std::size_t index = 0; index < lineage.size(); ++index) {
      if (lineage[index] != member && lineage[index] != group && lineage[index] != root) {
        continue;
      }
      if (index == 0 || lineage[index - 1] == member || lineage[index - 1] == group) {
        return std::nullopt;
      }

      return RejectedReporter{group, member, lineage[index - 1]};
    }

    return std::nullopt;
  }

  static constexpr std::chrono::nanoseconds report_timeout = std::chrono::seconds{2};
  RuntimeModel<Memory> &model_;
  const Agents &agents_;
  std::uint64_t sequence_ = 0;
  std::size_t pending_ = 0;
};

}
