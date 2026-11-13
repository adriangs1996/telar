#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <charconv>
#include <concepts>
#include <cstring>
#include <string_view>
#include <system_error>
#include <span>
#include "telar_base/memory/fixed_text.hpp"
#include <optional>
#include <algorithm>
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <chrono>
#include <limits>
#include <exception>
#include <iostream>
#include <string>
#include <type_traits>



import telar.gui.machines.discovery;
import telar.gui.machines.picker;
import telar.gui.transport.runtime_link;

namespace {

using namespace telar::gui;
using namespace telar::gui::test;

void failuresKeepTheOriginalBoundedSingleLineUtf8() {
  RuntimeLink link;
  constexpr std::string_view text = " \tbroken\n\rconnection\x7f \t";
  link.fail(text);
  require(link.failure() && *link.failure() == "broken  connection ", "failure text must trim only the original outer whitespace and replace interior control bytes");
  const std::string target(RuntimeLink::target_bytes - 1, 'x');
  link.name(target + "🌍");
  require(link.target() == target, "a target must stop before a split UTF-8 scalar");
  const std::string failure(RuntimeLink::failure_bytes - 1, 'x');
  link.fail(failure + "🌍");
  require(link.failure() == failure, "the bounded failure must stop at the same UTF-8 boundary");
  link.fail("\xff");
  require(!link.failure(), "invalid kept UTF-8 must not become replacement characters");
  link.name("\xff");
  require(link.target().empty(), "an invalid target must be empty as in the original");
  link.fail(" \t\r\n");
  require(!link.failure(), "whitespace alone must not create an empty detail row");
  static_assert(std::is_trivially_destructible_v<RuntimeLink>);
}

void retriesSaturateAndOnlyHealthyConnectionsEarnFastBackoff() {
  RuntimeLink link;
  link.start("host");
  require(link.phase == MachinePhase::connecting && link.headline().view() == "Connecting to host…", "a first start must name its target without a retry counter");
  link.connectionFailed(MachineError::endpoint_unavailable, "Timed out");
  constexpr std::array delays{500, 1000, 2000, 4000, 8000, 16000, 30000, 30000};
  for (const auto delay : delays) {
    require(link.phase == MachinePhase::lost && link.retryDelayMilliseconds() == delay, "the original retry doubles from half a second up to thirty seconds");
    require(link.retry(), "a lost link must admit its next attempt");
    require(!link.retry(), "an already connecting link must not admit a second attempt");
    link.connectionFailed(MachineError::endpoint_unavailable, "Still unavailable");
  }

  constexpr std::uint64_t first_connected_ns = 1;
  const auto attempts = link.attempt;
  link.adopt(first_connected_ns);
  require(link.sessions == 1 && !link.failure() && link.attempt == attempts, "a short recovered session must retain its retry history");
  link.lose("Lost quickly", first_connected_ns + RuntimeLink::healthy_after_ns - 1);
  require(link.attempt == attempts, "a connection below the original healthy duration must keep its slower backoff");
  require(link.retry(), "the quick loss must remain retryable");
  link.adopt(first_connected_ns);
  link.lose("Lost after health", first_connected_ns + RuntimeLink::healthy_after_ns);
  require(link.attempt == 0 && link.retryDelayMilliseconds() == RuntimeLink::first_retry_ms, "sixty healthy seconds must restore the original first retry");
  link.attempt = std::numeric_limits<std::uint16_t>::max();
  require(link.retry() && link.attempt == std::numeric_limits<std::uint16_t>::max(), "attempt counters must saturate instead of wrapping");
  link.sessions = std::numeric_limits<std::uint32_t>::max();
  link.adopt(first_connected_ns);
  require(link.sessions == std::numeric_limits<std::uint32_t>::max(), "session counters must saturate instead of replacing a connected session count with zero");
}

void permanentFailureWaitsForThePersonAndRetainsItsReasonUntilAdoption() {
  RuntimeLink link;
  link.start("host");
  link.connectionFailed(MachineError::authentication_failed, "Permission denied");
  require(link.phase == MachinePhase::failed && !link.setup_repairs && !link.retry(), "an authentication failure must wait for an explicit retry");
  require(link.headline().view() == "Cannot connect to host; retry it from the machine list", "permanent failure chrome must use the original instruction");
  require(link.retryNow() && link.attempt == 0 && link.failure() == "Permission denied", "an explicit retry resets attempts while keeping why it waited");
  require(!link.retryNow(), "an explicit retry must not replace an attempt already in progress");
  link.connectionFailed(MachineError::remote_program_missing, "Missing build");
  require(link.setup_repairs && link.headline().view() == "host lacks this telar build; choose it in the machine list to set it up", "a setup-repairable failure must point at the machine list");
  link.name(std::string(RuntimeLink::target_bytes, 'x'));
  require(link.headline().view() == "This machine lacks this telar build", "an oversized formatted headline must use the original whole fallback");
  link.stop();
  require(link.phase == MachinePhase::stopped && !link.setup_repairs && !link.failure() && !link.retryNow(), "stopping must retire failure ownership and refuse retries");
}

}

int main() {
  try {
    failuresKeepTheOriginalBoundedSingleLineUtf8();
    retriesSaturateAndOnlyHealthyConnectionsEarnFastBackoff();
    permanentFailureWaitsForThePersonAndRetainsItsReasonUntilAdoption();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
