#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include "telar_wire/protocol/runtime.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <stdexcept>

import telar.testing;
import telar.gui.tests.metrics_fixture;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.features.status_bar;
import telar.gui.foundation.core;
import telar.gui.features.machines;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::machines;
  using namespace telar::gui::features::status_bar;
  using telar::gui::test::hostSample;
  using namespace telar::gui::application::tests::session_fixture;

  constexpr std::uint8_t initial_cpu = 42;
  constexpr std::uint8_t old_cpu = 99;
  constexpr std::uint8_t invalid_cpu = 101;

  void revisionsKeepTheLatestSampleAndHistory() {
    telar::gui::test::HostMetricsState metrics;
    CpuHistory::Samples buffer;

    check(!BarMetrics::available(BarMetric::cpu, metrics.sample()), "Missing metrics must stay hidden");
    check(metrics.history().ordered(buffer).empty(), "Missing metrics must have no CPU history");

    constexpr std::uint64_t first_revision = 8;

    check(metrics.update(hostSample(first_revision, initial_cpu)), "The first runtime sample must be accepted");
    check(!metrics.update(hostSample(first_revision, old_cpu)), "Repeated revisions must not alter the replica");
    check(!metrics.update(hostSample(first_revision - 1, old_cpu)), "Old revisions must not alter the replica");
    check(metrics.sample().cpu_percent == initial_cpu && metrics.history().ordered(buffer).size() == 1, "Rejected revisions must not append history");

    try {
      static_cast<void>(metrics.update(hostSample(first_revision + 1, invalid_cpu)));
      throw std::logic_error{"Invalid CPU percentages were accepted"};
    } catch (const std::runtime_error&) {
      check(metrics.sample().revision == first_revision && metrics.history().ordered(buffer).size() == 1, "Invalid new samples must preserve the previous replica");
    }
  }

  void historyKeepsOnlyTheLastSamplesInOrder() {
    telar::gui::test::HostMetricsState metrics;
    CpuHistory::Samples buffer;
    constexpr std::uint64_t sample_count = (3 * CpuHistory::capacity) + 7;
    constexpr std::uint64_t percent_count = 101;

    for (std::uint64_t revision = 1; revision <= sample_count; ++revision) {
      check(metrics.update(hostSample(revision, static_cast<std::uint8_t>(revision % percent_count))), "Increasing revisions must be accepted");
      const auto samples = metrics.history().ordered(buffer);
      const auto count = std::min<std::size_t>(revision, CpuHistory::capacity);

      check(samples.size() == count, "CPU history must stop growing at its fixed capacity");
      for (std::size_t index = 0; index < samples.size(); ++index) {
        const auto expected = (revision - count + 1 + index) % percent_count;

        check(samples[index] == expected, "Ring wraparound must preserve the most recent samples in chronological order");
      }
    }
  }

  void connectionReplacementAcceptsARevisionRestart() {
    SystemAllocator memory;
    telar::gui::application::tests::session_fixture::Transport transport;
    TestSession session{memory, transport};

    session.connected(1);
    constexpr std::uint64_t previous_revision = 9;

    check(telar::gui::application::tests::session_fixture::deliver(session, hostSample(previous_revision, initial_cpu)) == application::Change::metrics, "Metrics must publish their own change category");
    check(telar::gui::application::tests::session_fixture::deliver(session, hostSample(previous_revision, old_cpu)) == application::Change::none, "Duplicate wire messages must not invalidate the UI");
    const ProxyStatus proxy{.active = true, .scope = ProxyScope::wildcard, .system_trusted = true};

    check(telar::gui::application::tests::session_fixture::deliver(session, proxy) == application::Change::model, "Proxy status must join the same runtime session");
    session.disconnected();
    CpuHistory::Samples buffer;

    check(application::status_bar::metrics(session).sample().revision == previous_revision && application::status_bar::metrics(session).sample().cpu_percent == initial_cpu && application::status_bar::metrics(session).history().ordered(buffer).size() == 1, "A lost runtime must retain its last metric sample and CPU history until replacement adoption");
    check(session.proxyStatus().active && session.proxyStatus().scope == ProxyScope::wildcard && session.proxyStatus().system_trusted, "A lost runtime must retain proxy status while the old session stays visible");
    session.disconnected();
    check(application::status_bar::metrics(session).sample().revision == previous_revision, "Failed retries must not retire the last visible metric sample");
    session.connected(2);
    check(application::status_bar::metrics(session).sample().revision == 0 && application::status_bar::metrics(session).history().ordered(buffer).empty(), "Adopting the replacement runtime must clear the old metric replica and history");
    check(!session.proxyStatus().active && session.proxyStatus().scope == ProxyScope::exact && !session.proxyStatus().system_trusted, "Adopting the replacement runtime must reset its proxy status");
    check(telar::gui::application::tests::session_fixture::deliver(session, hostSample(1, initial_cpu)) == application::Change::metrics, "A replacement runtime may restart its revision counter");
  }

  void alertsDebouncePeaksAndReleaseWithAMargin() {
    telar::gui::test::HostMetricsState metrics;
    std::uint64_t revision = 0;
    const auto cpu = [&](std::uint8_t percent, ds::Option<std::uint8_t> battery = ds::none) {
      check(metrics.update(hostSample(++revision, percent, 0, battery)), "Each sample must be accepted");
      return metrics.severity(BarMetric::cpu);
    };

    check(cpu(MetricLevels::cpu_danger) == MetricSeverity::normal, "One CPU peak must not raise an alert");
    check(cpu(MetricLevels::cpu_danger) == MetricSeverity::normal, "Two CPU peaks must not raise an alert");
    check(cpu(MetricLevels::cpu_danger) == MetricSeverity::danger, "A peak held for three samples must raise the alert");
    check(cpu(MetricLevels::cpu_danger - 1) == MetricSeverity::danger, "A value just under the danger threshold must keep the alert");
    check(cpu(MetricLevels::cpu_danger - MetricAlerts::release_margin - 1) == MetricSeverity::warning, "Clearing the danger margin must fall to the level the value still holds");
    check(cpu(MetricLevels::cpu_warning - MetricAlerts::release_margin - 1) == MetricSeverity::normal, "Clearing the warning margin must end the alert");
    check(cpu(MetricLevels::cpu_danger) == MetricSeverity::normal && cpu(1) == MetricSeverity::normal && cpu(MetricLevels::cpu_danger) == MetricSeverity::normal, "An interrupted peak must start counting again");

    static_cast<void>(cpu(0, MetricLevels::battery_danger));
    check(metrics.severity(BarMetric::battery) == MetricSeverity::danger, "A low battery must alert at once");
    static_cast<void>(cpu(0, MetricLevels::battery_danger + MetricAlerts::release_margin));
    check(metrics.severity(BarMetric::battery) == MetricSeverity::danger, "A battery inside the margin must keep its alert");
    static_cast<void>(cpu(0));
    check(metrics.severity(BarMetric::battery) == MetricSeverity::normal, "A machine without a battery must have no battery alert");
  }

  void memoryAlertsUseTheShareOfTheTotal() {
    // Tenths of a GiB: 15 used of a 16 total, which rounds to 94 percent, and then 15.5 used.
    constexpr std::uint16_t used = 150;
    constexpr std::uint16_t total = 160;
    constexpr std::uint8_t used_percent = 94;
    constexpr std::uint16_t nearly_full = 155;
    auto sample = hostSample(1, 0, used);

    check(MetricLevels::severity(BarMetric::memory, sample) == MetricSeverity::normal, "Memory without a total must not alert");
    sample.memory_total_decigib = total;
    check(MetricLevels::percent(BarMetric::memory, sample) == used_percent && MetricLevels::severity(BarMetric::memory, sample) == MetricSeverity::warning, "15 of 16 GB must be a memory warning");
    sample.memory_used_decigib = nearly_full;
    check(MetricLevels::severity(BarMetric::memory, sample) == MetricSeverity::danger, "15.5 of 16 GB must be a memory danger");
  }

  const telar::testing::Case case_revisions_keep_the_latest_sample_and_history{"host_metrics.revisions_keep_the_latest_sample_and_history", revisionsKeepTheLatestSampleAndHistory};
  const telar::testing::Case case_history_keeps_only_the_last_samples_in_order{"host_metrics.history_keeps_only_the_last_samples_in_order", historyKeepsOnlyTheLastSamplesInOrder};
  const telar::testing::Case case_connection_replacement_accepts_a_revision_restart{"host_metrics.connection_replacement_accepts_a_revision_restart", connectionReplacementAcceptsARevisionRestart};
  const telar::testing::Case case_alerts_debounce_peaks_and_release_with_a_margin{"host_metrics.alerts_debounce_peaks_and_release_with_a_margin", alertsDebouncePeaksAndReleaseWithAMargin};
  const telar::testing::Case case_memory_alerts_use_the_share_of_the_total{"host_metrics.memory_alerts_use_the_share_of_the_total", memoryAlertsUseTheShareOfTheTotal};

}
