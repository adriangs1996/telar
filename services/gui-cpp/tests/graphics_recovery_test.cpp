#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <utility>
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "../core/memory.hpp"
#include "../core/terminal_size.hpp"
#include <atomic>
#include <exception>
#include "telar_config/graphics/limits.hpp"
#include <variant>
#include "../terminal/screen.hpp"
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
#include "session_fixture.hpp"
#include <iostream>
#include <string>

#include "core/memory.hpp"


import telar.gui.application.host_effects;
import telar.gui.application.workspace_replica;
import telar.gui.application.session;
import telar.gui.graphics.pauses;
import telar.gui.graphics.texture_cache;

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::deliver;
using telar::gui::test::openFirstPane;
using telar::gui::test::require;
using telar::gui::test::Transport;

struct Clock {
  static inline std::uint64_t now_ns = 0;

  static std::uint64_t nowNanoseconds() noexcept {
    return now_ns;
  }
};

class RecoveryTransport : public Transport {
public:
  template <typename Message>
  void send(const Message &message) {
    if constexpr (std::same_as<Message, RequestGraphicsSnapshot> || std::same_as<Message, GraphicsCredit>) {
      if (reject_graphics) {
        throw EncodingError{"Graphics transport is full"};
      }
    }

    if constexpr (std::same_as<Message, ReportLimit>) {
      if (reject_reports) {
        throw EncodingError{"Report transport is full"};
      }
    }

    Transport::send(message);
  }

  void recover(std::string_view reason) {
    recovery_reason = reason;
  }

  bool reject_graphics = false;
  bool reject_reports = false;
  std::string recovery_reason;
};

constexpr std::uint32_t image_side = 2;
constexpr std::size_t pixel_bytes = std::size_t{image_side} * image_side * 4;
constexpr GraphicsHeader header{.pane_id = 1, .revision = 1};
constexpr std::array<Byte, pixel_bytes> pixels{};

void windowLimitUsesTheSharedReportAndNotificationLedger() {
  Clock::now_ns = 0;
  SystemAllocator memory;
  RecoveryTransport transport;
  Session<SystemAllocator, RecoveryTransport, Clock> client{memory, transport};
  openFirstPane(client, transport);
  constexpr LimitReach reach{.name = ImagePlacementSelection::limit_name, .noun = ImagePlacementSelection::limit_noun, .value = ImagePlacementSelection::capacity, .requested = ImagePlacementSelection::capacity + 1};
  client.reportLimit(reach);
  const auto report = transport.last<ReportLimit>();
  require(report.reach.name == reach.name && report.reach.noun == reach.noun && report.reach.value == reach.value && report.reach.requested == reach.requested && report.reach.route.empty(), "a window limit must preserve its named bound without pretending to be a failed runtime message");
  const auto &notice = client.notifications().items().front();
  require(notice.title.view() == "Limit reached" && notice.level == NotificationLevel::warning && notice.target.kind == NotificationTarget::Kind::none, "a window limit must publish the original global warning");
  require(notice.message.view() == "gui.images.placements_per_frame: 2049 image placements; limit 2048", "the warning must include requested and available placements");
  client.reportLimit(reach);
  require(client.notifications().items().size() == 1 && transport.count(ClientTag::report_limit) == 1, "repeated reaches must respect the notification and runtime reporting intervals");
  Clock::now_ns = LimitReports::report_interval_ms * NotificationInput::nanoseconds_per_millisecond;
  client.reportLimit(reach);
  require(transport.last<ReportLimit>().hits == 2, "the next runtime report must include reaches collected during its interval");
  require(client.ready() && !client.graphicsPaused(1), "a presentation limit must preserve the runtime link and image stream");
}

ImageDescription description(std::uint32_t id, std::uint64_t generation = 1) {
  return {.key = {.image_id = id, .generation = generation}, .format = ImageFormat::rgba, .width = image_side, .height = image_side, .byte_len = pixel_bytes};
}

void replacementDoesNotConsumeAnotherLogicalImageSlot() {
  SystemAllocator memory;
  GraphicsBudget budget;
  GraphicsStore store{memory, budget};
  for (std::uint32_t id = 1; id <= decltype(store)::image_capacity; ++id) {
    const auto image = description(id);
    store.image({.header = header, .image = image});
    store.chunk({.header = header, .key = image.key, .bytes = pixels});
  }

  const auto replacement = description(1, 2);
  store.image({.header = header, .image = replacement});
  require(store.findImage({.image_id = 1, .generation = 1}) == nullptr && store.readyImage(replacement.key) == nullptr, "a replacement must release unreferenced CPU pixels while a presentation cache owns its stand-in");
  store.chunk({.header = header, .key = replacement.key, .bytes = pixels});
  require(store.readyImage(replacement.key)->description().key.generation == replacement.key.generation, "the replacement must become visible when its pixels finish");
}

void supersededIncompleteHeadersStayWithinOneImageAllocation() {
  SystemAllocator memory;
  GraphicsBudget budget;
  GraphicsStore store{memory, budget};
  constexpr std::uint64_t generations = decltype(store)::image_capacity * 2;
  for (std::uint64_t generation = 1; generation <= generations; ++generation) {
    store.image({.header = header, .image = description(1, generation)});
    require(budget.used == pixel_bytes, "superseded incomplete headers must release their pixel storage before admission");
  }

  require(store.takeCredit() == (generations - 1) * pixel_bytes, "superseded transfers must return every released byte exactly once");
}

void virtualPlacementIdentityDoesNotDependOnItsImage() {
  SystemAllocator memory;
  GraphicsBudget budget;
  GraphicsStore store{memory, budget};
  const auto first = description(1);
  const auto second = description(2);
  store.image({.header = header, .image = first});
  store.image({.header = header, .image = second});
  constexpr std::uint64_t placement_id = 7;
  store.placement({.header = header, .placement = {.key = first.key, .virtual_id = placement_id}});
  store.placement({.header = header, .placement = {.key = second.key, .virtual_id = placement_id}});
  require(store.placements().size() == 1 && store.placements().front().key.image_id == second.key.image_id, "updating a virtual placement to another image must replace the existing placement");
}

template <typename Client>
void failedSnapshot(Client &client, std::uint64_t revision) {
  const GraphicsHeader snapshot{.pane_id = 1, .revision = revision};
  deliver(client, GraphicsSnapshot{.header = snapshot, .phase = SnapshotPhase::begin});
  constexpr auto image_count = GraphicsStore<SystemAllocator>::image_capacity + 1;
  for (std::uint32_t id = 1; id <= image_count; ++id) {
    deliver(client, GraphicsImage{.header = snapshot, .image = description(id)});
  }

  deliver(client, GraphicsSnapshot{.header = snapshot, .phase = SnapshotPhase::end});
}

void repeatedOversizedSnapshotsUseThePaneBudget() {
  SystemAllocator memory;
  Transport transport;
  Session<SystemAllocator, Transport, Clock> client{memory, transport};
  openFirstPane(client, transport);
  constexpr std::uint64_t failed_snapshots = 4;
  for (std::uint64_t revision = 1; revision <= failed_snapshots; ++revision) {
    failedSnapshot(client, revision);
  }

  constexpr std::size_t expected_resyncs = 3;
  require(transport.count(ClientTag::request_graphics_snapshot) == expected_resyncs, "a fourth oversized snapshot must wait instead of creating an unbounded retry loop");
  require(client.notifications().items().size() == 1, "one pause must publish one notice across repeated failed snapshots");
  require(client.ready(), "a graphics pause must preserve the runtime link and terminal input");
}

void pausedDeletesReturnCreditAndACompleteSnapshotClearsTheMarker() {
  Clock::now_ns = 0;
  SystemAllocator memory;
  RecoveryTransport transport;
  Session<SystemAllocator, RecoveryTransport, Clock> client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, PaneForeground{.pane_id = 1, .name = "nvim"});
  failedSnapshot(client, 1);
  require(client.graphicsPaused(1), "the marker must start with the first failed transfer");
  const auto &notice = client.notifications().items().front();
  require(notice.title.view() == "Images paused in pane 1: nvim", "a pause must name the pane by its displayed index and foreground");
  require(notice.message.view() == "GraphicsImageLimitExceeded: limit reached" && notice.level == NotificationLevel::warning, "the pause must describe the actual limit as a warning");
  require(notice.target.kind == NotificationTarget::Kind::pane && notice.target.id == 1, "a pause notice must focus its pane when clicked");
  const auto report = transport.last<ReportLimit>();
  require(report.hits == 1 && report.reach.name == "GraphicsImageLimitExceeded" && report.reach.route == "runtime_message", "the runtime must receive the first limit reach");

  deliver(client, GraphicsDeleteImage{.header = header, .key = description(1).key});
  require(transport.last<GraphicsCredit>().bytes == pixel_bytes, "deletes must still release credits while the image stream is paused");
  constexpr GraphicsHeader resumed{.pane_id = 1, .revision = 2};
  deliver(client, GraphicsSnapshot{.header = resumed, .phase = SnapshotPhase::begin});
  require(client.graphicsPaused(1), "a snapshot begin alone must retain the paused marker");
  const auto image = description(1, 2);
  deliver(client, GraphicsImage{.header = resumed, .image = image});
  deliver(client, GraphicsImageChunk{.header = resumed, .key = image.key, .bytes = pixels});
  deliver(client, GraphicsSnapshot{.header = resumed, .phase = SnapshotPhase::end});
  require(!client.graphicsPaused(1) && !client.graphicsResumeDeadline(), "only an applied complete snapshot ends the pause");
}

void resumeDeadlineAndFocusKeepTheBackoff() {
  Clock::now_ns = 0;
  SystemAllocator memory;
  RecoveryTransport transport;
  Session<SystemAllocator, RecoveryTransport, Clock> client{memory, transport};
  openFirstPane(client, transport);
  for (std::uint64_t revision = 1; revision <= 4; ++revision) {
    failedSnapshot(client, revision);
  }

  constexpr auto window = GraphicsPauses::healthy_window_ns;
  require(client.graphicsResumeDeadline() == window, "the first exhausted window must wait sixty awake seconds");
  Clock::now_ns = window - 1;
  client.resumeGraphics();
  require(transport.count(ClientTag::request_graphics_snapshot) == 3, "a retry must not run before its deadline");
  Clock::now_ns = window;
  client.resumeGraphics();
  require(transport.count(ClientTag::request_graphics_snapshot) == 4 && !client.graphicsResumeDeadline(), "a timer must request recovery without receiving a runtime message");
  constexpr std::uint64_t first_retry_revision = 5;
  constexpr std::uint64_t last_retry_revision = 7;
  for (auto revision = first_retry_revision; revision <= last_retry_revision; ++revision) {
    failedSnapshot(client, revision);
  }

  require(client.graphicsResumeDeadline() == 3 * window, "the next exhausted window must double its delay");
  Clock::now_ns = 2 * window;
  client.focusPane(1);
  require(transport.count(ClientTag::request_graphics_snapshot) == last_retry_revision && !client.graphicsResumeDeadline(), "focusing a pane must accelerate a doubled wait after one healthy window");
}

void failedReportsRetainHitsAndNeverDropTheLink() {
  Clock::now_ns = 0;
  SystemAllocator memory;
  RecoveryTransport transport;
  Session<SystemAllocator, RecoveryTransport, Clock> client{memory, transport};
  openFirstPane(client, transport);
  transport.reject_reports = true;
  failedSnapshot(client, 1);
  require(client.ready() && transport.recovery_reason.empty(), "a best effort diagnostic report must not disconnect the terminal");
  transport.reject_reports = false;
  failedSnapshot(client, 2);
  require(transport.last<ReportLimit>().hits == 2, "the next report must recover hits from an unsent report");
  failedSnapshot(client, 3);
  require(transport.count(ClientTag::report_limit) == 1, "a delivered limit report must be paced independently of snapshot retries");
  Clock::now_ns = LimitReports::report_interval_ms * NotificationInput::nanoseconds_per_millisecond;
  failedSnapshot(client, 4);
  require(transport.last<ReportLimit>().hits == 2 && transport.count(ClientTag::report_limit) == 2, "the next reporting interval must include the accumulated reaches");
}

void criticalDeliveryAndMalformedImagesRecoverTheRuntimeLink() {
  for (const bool malformed : {false, true}) {
    Clock::now_ns = 0;
    SystemAllocator memory;
    RecoveryTransport transport;
    Session<SystemAllocator, RecoveryTransport, Clock> client{memory, transport};
    openFirstPane(client, transport);
    transport.reject_graphics = !malformed;
    bool failed = false;
    try {
      if (malformed) {
        deliver(client, GraphicsImageChunk{.header = header, .key = description(1).key, .bytes = pixels});
      } else {
        failedSnapshot(client, 1);
      }
    } catch (const EncodingError &) {
      failed = true;
    }

    require(failed && !client.ready() && !transport.recovery_reason.empty(), "a malformed transfer or undeliverable resync must recover the link instead of leaving a wrong connected replica");
  }
}

void snapshotMismatchRequestsRecoveryWithoutALimitNotice() {
  Clock::now_ns = 0;
  SystemAllocator memory;
  Transport transport;
  Session<SystemAllocator, Transport, Clock> client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, GraphicsSnapshot{.header = header, .phase = SnapshotPhase::begin});
  deliver(client, GraphicsImage{.header = {.pane_id = 1, .revision = 2}, .image = description(1)});
  require(client.ready() && transport.count(ClientTag::request_graphics_snapshot) == 1, "a revision mismatch must request a graphics snapshot");
  require(!client.graphicsPaused(1) && client.notifications().items().empty(), "revision drift must not be reported as a resource limit");
}

}

int main() {
  try {
    replacementDoesNotConsumeAnotherLogicalImageSlot();
    windowLimitUsesTheSharedReportAndNotificationLedger();
    supersededIncompleteHeadersStayWithinOneImageAllocation();
    virtualPlacementIdentityDoesNotDependOnItsImage();
    repeatedOversizedSnapshotsUseThePaneBudget();
    pausedDeletesReturnCreditAndACompleteSnapshotClearsTheMarker();
    resumeDeadlineAndFocusKeepTheBackoff();
    failedReportsRetainHitsAndNeverDropTheLink();
    criticalDeliveryAndMalformedImagesRecoverTheRuntimeLink();
    snapshotMismatchRequestsRecoveryWithoutALimitNotice();
    std::cout << "gui-graphics-recovery: passed\n";
  } catch (const std::exception &error) {
    std::cerr << "gui-graphics-recovery: " << error.what() << '\n';

    return 1;
  }
}
