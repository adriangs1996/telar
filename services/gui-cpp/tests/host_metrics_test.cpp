#include "application/host_metrics.hpp"
#include "application/session.hpp"
#include "assertions.hpp"
#include "core/cpu_history.hpp"
#include "core/memory.hpp"
#include "metrics_fixture.hpp"
#include "presentation/bar_metrics.hpp"
#include "session_fixture.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <stdexcept>

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::hostSample;
using telar::gui::test::require;

constexpr std::uint8_t initial_cpu = 42;
constexpr std::uint8_t old_cpu = 99;
constexpr std::uint8_t invalid_cpu = 101;

void revisionsKeepTheLatestSampleAndHistory() {
  HostMetrics metrics;
  CpuHistory::Samples buffer;
  require(!BarMetrics::available(BarMetric::cpu, metrics.sample()), "Missing metrics must stay hidden");
  require(metrics.history().ordered(buffer).empty(), "Missing metrics must have no CPU history");

  constexpr std::uint64_t first_revision = 8;
  require(metrics.update(hostSample(first_revision, initial_cpu)), "The first runtime sample must be accepted");
  require(!metrics.update(hostSample(first_revision, old_cpu)), "Repeated revisions must not alter the replica");
  require(!metrics.update(hostSample(first_revision - 1, old_cpu)), "Old revisions must not alter the replica");
  require(metrics.sample().cpu_percent == initial_cpu && metrics.history().ordered(buffer).size() == 1, "Rejected revisions must not append history");

  try {
    static_cast<void>(metrics.update(hostSample(first_revision + 1, invalid_cpu)));
    throw std::logic_error{"Invalid CPU percentages were accepted"};
  } catch (const std::runtime_error &) {
    require(metrics.sample().revision == first_revision && metrics.history().ordered(buffer).size() == 1, "Invalid new samples must preserve the previous replica");
  }
}

void historyKeepsOnlyTheLastSamplesInOrder() {
  HostMetrics metrics;
  CpuHistory::Samples buffer;
  constexpr std::uint64_t sample_count = (3 * CpuHistory::capacity) + 7;
  constexpr std::uint64_t percent_count = 101;
  for (std::uint64_t revision = 1; revision <= sample_count; ++revision) {
    require(metrics.update(hostSample(revision, static_cast<std::uint8_t>(revision % percent_count))), "Increasing revisions must be accepted");
    const auto samples = metrics.history().ordered(buffer);
    const auto count = std::min<std::size_t>(revision, CpuHistory::capacity);
    require(samples.size() == count, "CPU history must stop growing at its fixed capacity");
    for (std::size_t index = 0; index < samples.size(); ++index) {
      const auto expected = (revision - count + 1 + index) % percent_count;
      require(samples[index] == expected, "Ring wraparound must preserve the most recent samples in chronological order");
    }
  }
}

void connectionReplacementAcceptsARevisionRestart() {
  SystemAllocator memory;
  telar::gui::test::Transport transport;
  Session session{memory, transport};
  session.connected(1);
  constexpr std::uint64_t previous_revision = 9;
  require(telar::gui::test::deliver(session, hostSample(previous_revision, initial_cpu)) == Change::metrics, "Metrics must publish their own change category");
  require(telar::gui::test::deliver(session, hostSample(previous_revision, old_cpu)) == Change::none, "Duplicate wire messages must not invalidate the UI");
  const ProxyStatus proxy{.active = true, .scope = ProxyScope::wildcard, .system_trusted = true};
  require(telar::gui::test::deliver(session, proxy) == Change::model, "Proxy status must join the same runtime session");
  session.disconnected();
  CpuHistory::Samples buffer;
  require(session.metrics().revision == previous_revision && session.metrics().cpu_percent == initial_cpu && session.hostMetrics().history().ordered(buffer).size() == 1, "A lost runtime must retain its last metric sample and CPU history until replacement adoption");
  require(session.proxyStatus().active && session.proxyStatus().scope == ProxyScope::wildcard && session.proxyStatus().system_trusted, "A lost runtime must retain proxy status while the old session stays visible");
  session.disconnected();
  require(session.metrics().revision == previous_revision, "Failed retries must not retire the last visible metric sample");
  session.connected(2);
  require(session.metrics().revision == 0 && session.hostMetrics().history().ordered(buffer).empty(), "Adopting the replacement runtime must clear the old metric replica and history");
  require(!session.proxyStatus().active && session.proxyStatus().scope == ProxyScope::exact && !session.proxyStatus().system_trusted, "Adopting the replacement runtime must reset its proxy status");
  require(telar::gui::test::deliver(session, hostSample(1, initial_cpu)) == Change::metrics, "A replacement runtime may restart its revision counter");
}

}

int main() {
  try {
    revisionsKeepTheLatestSampleAndHistory();
    historyKeepsOnlyTheLastSamplesInOrder();
    connectionReplacementAcceptsARevisionRestart();

    return 0;
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));

    return 1;
  }
}
