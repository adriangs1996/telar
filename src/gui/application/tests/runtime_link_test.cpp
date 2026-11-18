#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <type_traits>

import telar.testing;
import telar.gui.features.machines;
import telar.gui.application;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::machines;

  void failuresKeepTheOriginalBoundedSingleLineUtf8() {
    application::RuntimeLink link;
    constexpr std::string_view text = " \tbroken\n\rconnection\x7f \t";

    link.fail(text);
    check(link.failure() && *link.failure() == "broken  connection ", "failure text must trim only the original outer whitespace and replace interior control bytes");
    const std::string target(application::RuntimeLink::target_bytes - 1, 'x');

    link.name(target + "🌍");
    check(link.target() == target, "a target must stop before a split UTF-8 scalar");
    const std::string failure(application::RuntimeLink::failure_bytes - 1, 'x');

    link.fail(failure + "🌍");
    check(link.failure() == failure, "the bounded failure must stop at the same UTF-8 boundary");
    link.fail("\xff");
    check(!link.failure(), "invalid kept UTF-8 must not become replacement characters");
    link.name("\xff");
    check(link.target().empty(), "an invalid target must be empty as in the original");
    link.fail(" \t\r\n");
    check(!link.failure(), "whitespace alone must not create an empty detail row");
    static_assert(std::is_trivially_destructible_v<application::RuntimeLink>);
  }

  void retriesSaturateAndOnlyHealthyConnectionsEarnFastBackoff() {
    application::RuntimeLink link;

    link.start("host");
    check(link.phase == MachinePhase::connecting && link.headline().view() == "Connecting to host…", "a first start must name its target without a retry counter");
    link.connectionFailed(MachineError::endpoint_unavailable, "Timed out");
    constexpr telar::ds::Array delays{500, 1000, 2000, 4000, 8000, 16000, 30000, 30000};

    for (const auto delay : delays) {
      check(link.phase == MachinePhase::lost && link.retryDelayMilliseconds() == delay, "the original retry doubles from half a second up to thirty seconds");
      check(link.retry(), "a lost link must admit its next attempt");
      check(!link.retry(), "an already connecting link must not admit a second attempt");
      link.connectionFailed(MachineError::endpoint_unavailable, "Still unavailable");
    }

    constexpr std::uint64_t first_connected_ns = 1;
    const auto attempts = link.attempt;

    link.adopt(first_connected_ns);
    check(link.sessions == 1 && !link.failure() && link.attempt == attempts, "a short recovered session must retain its retry history");
    link.lose("Lost quickly", first_connected_ns + application::RuntimeLink::healthy_after_ns - 1);
    check(link.attempt == attempts, "a connection below the original healthy duration must keep its slower backoff");
    check(link.retry(), "the quick loss must remain retryable");
    link.adopt(first_connected_ns);
    link.lose("Lost after health", first_connected_ns + application::RuntimeLink::healthy_after_ns);
    check(link.attempt == 0 && link.retryDelayMilliseconds() == application::RuntimeLink::first_retry_ms, "sixty healthy seconds must restore the original first retry");
    link.attempt = std::numeric_limits<std::uint16_t>::max();
    check(link.retry() && link.attempt == std::numeric_limits<std::uint16_t>::max(), "attempt counters must saturate instead of wrapping");
    link.sessions = std::numeric_limits<std::uint32_t>::max();
    link.adopt(first_connected_ns);
    check(link.sessions == std::numeric_limits<std::uint32_t>::max(), "session counters must saturate instead of replacing a connected session count with zero");
  }

  void permanentFailureWaitsForThePersonAndRetainsItsReasonUntilAdoption() {
    application::RuntimeLink link;

    link.start("host");
    link.connectionFailed(MachineError::authentication_failed, "Permission denied");
    check(link.phase == MachinePhase::failed && !link.setup_repairs && !link.retry(), "an authentication failure must wait for an explicit retry");
    check(link.headline().view() == "Cannot connect to host; retry it from the machine list", "permanent failure chrome must use the original instruction");
    check(link.retryNow() && link.attempt == 0 && link.failure() == "Permission denied", "an explicit retry resets attempts while keeping why it waited");
    check(!link.retryNow(), "an explicit retry must not replace an attempt already in progress");
    link.connectionFailed(MachineError::remote_program_missing, "Missing build");
    check(link.setup_repairs && link.headline().view() == "host lacks this telar build; choose it in the machine list to set it up", "a setup-repairable failure must point at the machine list");
    link.name(std::string(application::RuntimeLink::target_bytes, 'x'));
    check(link.headline().view() == "This machine lacks this telar build", "an oversized formatted headline must use the original whole fallback");
    link.stop();
    check(link.phase == MachinePhase::stopped && !link.setup_repairs && !link.failure() && !link.retryNow(), "stopping must retire failure ownership and refuse retries");
  }

  const telar::testing::Case case_failures_keep_the_original_bounded_single_line_utf8{"runtime_link.failures_keep_the_original_bounded_single_line_utf8", failuresKeepTheOriginalBoundedSingleLineUtf8};
  const telar::testing::Case case_retries_saturate_and_only_healthy_connections_earn_fast_backoff{"runtime_link.retries_saturate_and_only_healthy_connections_earn_fast_backoff", retriesSaturateAndOnlyHealthyConnectionsEarnFastBackoff};
  const telar::testing::Case case_permanent_failure_waits_for_the_person_and_retains_its_reason_until_adoption{"runtime_link.permanent_failure_waits_for_the_person_and_retains_its_reason_until_adoption", permanentFailureWaitsForThePersonAndRetainsItsReasonUntilAdoption};

}
