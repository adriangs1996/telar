module telar.gui.application;

import std;
import telar.gui.foundation.text;
import telar.gui.foundation.system;
import telar.gui.core.json_writer;
import telar.gui.foundation.core;
import telar.tbc;
import telar.gui.features.window;
import telar.gui.text.notification_payload;
import telar.base.diagnostics;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.vocabulary;

namespace telar::gui::application {

  std::optional<AcknowledgeAgent> AgentAcknowledgement::take(std::optional<FocusedAgent> agent) noexcept {
    if (!agent) {
      return std::nullopt;
    }

    const bool already = acknowledged_ && acknowledged_->pane_id == agent->pane_id && acknowledged_->pane_generation == agent->pane_generation;

    if (agent->status != AgentStatus::done) {
      if (already) {
        acknowledged_.reset();
      }

      return std::nullopt;
    }

    if (already) {
      return std::nullopt;
    }

    acknowledged_ = AcknowledgeAgent{agent->pane_id, agent->pane_generation};

    return acknowledged_;
  }

  void UnsupportedClientCommand::operator()([[maybe_unused]] const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) const {
    reply.status = ClientCommandStatus::failed;
    reply.text = "Command is not supported by this client";
  }

  void HostEffects::notePaneInput([[maybe_unused]] features::window::FramePacer::Pane pane) noexcept {}

  bool DiscardHostEffects::postNotification([[maybe_unused]] const NotificationPayload& payload) noexcept {
    return false;
  }

  bool DiscardHostEffects::playSound([[maybe_unused]] AgentSound sound) noexcept {
    return false;
  }

  bool RuntimeTransport::report(std::span<const Byte> message) {
    send(message);

    return true;
  }

  void RuntimeTransport::willDetach([[maybe_unused]] std::uint64_t pane_id) {}

  void RuntimeTransport::recover([[maybe_unused]] std::string_view reason) {}

  bool RuntimeTransport::supportsSharedMemory() const noexcept {
    return false;
  }

  system::SharedImageSource RuntimeTransport::sharedImage([[maybe_unused]] std::string_view name) const {
    throw EncodingError{"Shared graphics was not negotiated"};
  }

  bool HostMetrics::update(const SystemMetrics& sample) {
    sample.validate();
    if (sample.revision <= sample_.revision) {
      return false;
    }

    sample_ = sample;
    history_.push(sample.cpu_percent);
    alerts_.update(sample);

    return true;
  }

  const SystemMetrics& HostMetrics::sample() const noexcept {
    return sample_;
  }

  const CpuHistory& HostMetrics::history() const noexcept {
    return history_;
  }

  MetricSeverity HostMetrics::severity(BarMetric metric) const noexcept {
    return alerts_.severity(metric);
  }

  LimitReach LimitReports::Row::reach() const noexcept {
    return {.name = name.view(), .noun = noun.view(), .value = value, .requested = requested, .route = route.view()};
  }

  auto LimitReports::record(LimitReach reach, Time sampled, std::uint32_t hits) -> Recorded {
    const auto name = reach.name.substr(0, name_capacity);
    const auto found = find(name);
    const auto slot = found ? *found : insert(name);
    auto& row = rows_[slot];

    row.noun.assign(reach.noun.substr(0, noun_capacity));
    row.route.assign(reach.route.substr(0, route_capacity));
    row.value = reach.value;
    if (reach.requested) {
      row.requested = reach.requested;
    }

    row.hits = saturatedAdd(row.hits, static_cast<std::uint64_t>(hits));
    row.unreported = saturatedAdd(row.unreported, hits);
    row.last_ms = sampled.real_ms;
    const bool show = !row.shown_ms || elapsed(sampled.awake_ms, *row.shown_ms, notice_interval_ms);
    if (show) {
      row.shown_ms = sampled.awake_ms;
    }

    return {.slot = {slot}, .show = show};
  }

  std::optional<std::uint32_t> LimitReports::takeReport(Slot slot, std::int64_t awake_ms) noexcept {
    auto& row = rows_[slot.value];
    if (row.unreported == 0 || (row.reported_ms && !elapsed(awake_ms, *row.reported_ms, report_interval_ms))) {
      return std::nullopt;
    }

    const auto hits = std::exchange(row.unreported, 0);

    row.reported_ms = awake_ms;

    return hits;
  }

  void LimitReports::restoreReport(Slot slot, std::uint32_t hits) noexcept {
    auto& row = rows_[slot.value];

    row.unreported = saturatedAdd(row.unreported, hits);
    row.reported_ms.reset();
  }

  auto LimitReports::row(Slot slot) const -> const Row& {
    return rows_.at(slot.value);
  }

  auto LimitReports::rows() const noexcept -> std::span<const Row> {
    return std::span{rows_}.first(count_);
  }

  std::uint64_t LimitReports::evicted() const noexcept {
    return evicted_;
  }

  auto LimitReports::describe(LimitReach reach, std::uint64_t hits) -> BoundedText<description_capacity> {
    BoundedText<description_capacity> text;

    text.append(reach.name);
    text.append(": ");
    if (reach.requested) {
      text.appendDecimal(*reach.requested);
      appendNoun(text, reach.noun);
      text.append("; limit ");
      text.appendDecimal(reach.value);
    } else if (reach.value == 0) {
      text.append("limit reached");
    } else {
      text.append("limit ");
      text.appendDecimal(reach.value);
      appendNoun(text, reach.noun);
      text.append(" reached");
    }

    if (hits > 1) {
      text.append(" (");
      text.appendDecimal(hits);
      text.append(" times)");
    }

    return text;
  }

  template <typename Number>
  Number LimitReports::saturatedAdd(Number left, Number right) noexcept {
    return left + std::min(right, std::numeric_limits<Number>::max() - left);
  }

  bool LimitReports::elapsed(std::int64_t now_ms, std::int64_t since_ms, std::uint64_t interval_ms) noexcept {
    return now_ms >= since_ms && static_cast<std::uint64_t>(now_ms) - static_cast<std::uint64_t>(since_ms) >= interval_ms;
  }

  void LimitReports::appendNoun(BoundedText<description_capacity>& text, std::string_view noun) {
    if (!noun.empty()) {
      text.append(" ");
      text.append(noun);
    }
  }

  std::optional<std::size_t> LimitReports::find(std::string_view name) const noexcept {
    for (std::size_t slot = 0; slot < count_; ++slot) {
      if (rows_[slot].name.view() == name) {
        return slot;
      }
    }

    return std::nullopt;
  }

  std::size_t LimitReports::insert(std::string_view name) {
    std::size_t slot = count_;

    if (count_ < capacity) {
      ++count_;
    } else {
      slot = oldest();
      evicted_ = saturatedAdd(evicted_, std::uint64_t{1});
    }

    rows_[slot] = {};
    rows_[slot].name.assign(name);

    return slot;
  }

  std::size_t LimitReports::oldest() const noexcept {
    std::size_t found = 0;

    for (std::size_t slot = 1; slot < count_; ++slot) {
      if (rows_[slot].last_ms < rows_[found].last_ms) {
        found = slot;
      }
    }

    return found;
  }

}
