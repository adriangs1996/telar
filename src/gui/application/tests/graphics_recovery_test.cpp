#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <string>
#include <string_view>

import telar.testing;
import telar.testing.test_memory;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.features.terminal.graphics;
import telar.gui.features.notifications;
import telar.wire.graphics;
import telar.wire.runtime;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.text.utf8;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::notifications;
  using namespace telar::gui::features::terminal::graphics;
  using namespace telar::gui::application::tests::session_fixture;

  struct Clock {
    static inline std::uint64_t now_ns = 0;

    static std::uint64_t nowNanoseconds() noexcept {
      return now_ns;
    }
  };

  class RecoveryTransport final : public Transport {
  public:
    void send(std::span<const Byte> message) override {
      const auto tag = static_cast<ClientTag>(message.front());
      if ((tag == MessageSchema<RequestGraphicsSnapshot>::tag || tag == MessageSchema<GraphicsCredit>::tag) && reject_graphics) {
        throw EncodingError{"Graphics transport is full"};
      }

      if (tag == MessageSchema<ReportLimit>::tag && reject_reports) {
        throw EncodingError{"Report transport is full"};
      }

      Transport::send(message);
    }

    void recover(std::string_view reason) override {
      recovery_reason = reason;
    }

    bool reject_graphics = false;
    bool reject_reports = false;
    std::string recovery_reason;
  };

  constexpr std::uint32_t image_side = 2;
  constexpr std::size_t pixel_bytes = std::size_t{image_side} * image_side * 4;
  constexpr GraphicsHeader header{.pane_id = 1, .revision = 1};
  constexpr ds::Array<Byte, pixel_bytes> pixels{};

  void windowLimitUsesTheSharedReportAndNotificationLedger() {
    Clock::now_ns = 0;
    SystemAllocator memory;
    RecoveryTransport transport;
    TestSession client{memory, transport, &Clock::nowNanoseconds};

    openFirstPane(client, transport);
    constexpr LimitReach reach{.name = ImagePlacementSelection::limit_name, .noun = ImagePlacementSelection::limit_noun, .value = ImagePlacementSelection::capacity, .requested = ImagePlacementSelection::capacity + 1};

    application::notifications::reportLimit(client, reach);
    const auto report = transport.last<ReportLimit>();

    check(report.reach.name == reach.name && report.reach.noun == reach.noun && report.reach.value == reach.value && report.reach.requested == reach.requested && report.reach.route.empty(), "a window limit must preserve its named bound without pretending to be a failed runtime message");
    const auto& notice = application::notifications::center(client).items().front();

    check(notice.title.view() == "Limit reached" && notice.level == NotificationLevel::warning && notice.target.kind == NotificationTarget::Kind::none, "a window limit must publish the original global warning");
    check(notice.message.view() == "gui.images.placements_per_frame: 2049 image placements; limit 2048", "the warning must include requested and available placements");
    application::notifications::reportLimit(client, reach);
    check(application::notifications::center(client).items().size() == 1 && transport.count(ClientTag::report_limit) == 1, "repeated reaches must respect the notification and runtime reporting intervals");
    Clock::now_ns = features::notifications::LimitNotices::report_interval_ms * NotificationInput::nanoseconds_per_millisecond;
    application::notifications::reportLimit(client, reach);
    check(transport.last<ReportLimit>().hits == 2, "the next runtime report must include reaches collected during its interval");
    check(client.ready() && !application::terminal::graphics::paused(client, 1), "a presentation limit must preserve the runtime link and image stream");
  }

  ImageDescription description(std::uint32_t id, std::uint64_t generation = 1) {
    return {.key = {.image_id = id, .generation = generation}, .format = ImageFormat::rgba, .width = image_side, .height = image_side, .byte_len = pixel_bytes};
  }

  void replacementDoesNotConsumeAnotherLogicalImageSlot() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    GraphicsBudget budget;
    GraphicsStore store{memory, budget};

    for (std::uint32_t id = 1; id <= decltype(store)::image_capacity; ++id) {
      const auto image = description(id);

      store.image({.header = header, .image = image});
      store.chunk({.header = header, .key = image.key, .bytes = pixels});
    }

    const auto replacement = description(1, 2);

    store.image({.header = header, .image = replacement});
    check(store.findImage({.image_id = 1, .generation = 1}) == nullptr && store.readyImage(replacement.key) == nullptr, "a replacement must release unreferenced CPU pixels while a presentation cache owns its stand-in");
    store.chunk({.header = header, .key = replacement.key, .bytes = pixels});
    check(store.readyImage(replacement.key)->description().key.generation == replacement.key.generation, "the replacement must become visible when its pixels finish");
  }

  void supersededIncompleteHeadersStayWithinOneImageAllocation() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    GraphicsBudget budget;
    GraphicsStore store{memory, budget};
    constexpr std::uint64_t generations = decltype(store)::image_capacity * 2;

    for (std::uint64_t generation = 1; generation <= generations; ++generation) {
      store.image({.header = header, .image = description(1, generation)});
      check(budget.used == pixel_bytes, "superseded incomplete headers must release their pixel storage before admission");
    }

    check(store.takeCredit() == (generations - 1) * pixel_bytes, "superseded transfers must return every released byte exactly once");
  }

  void virtualPlacementIdentityDoesNotDependOnItsImage() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    GraphicsBudget budget;
    GraphicsStore store{memory, budget};
    const auto first = description(1);
    const auto second = description(2);

    store.image({.header = header, .image = first});
    store.image({.header = header, .image = second});
    constexpr std::uint64_t placement_id = 7;

    store.placement({.header = header, .placement = {.key = first.key, .virtual_id = placement_id}});
    store.placement({.header = header, .placement = {.key = second.key, .virtual_id = placement_id}});
    check(store.placements().size() == 1 && store.placements().front().key.image_id == second.key.image_id, "updating a virtual placement to another image must replace the existing placement");
  }

  template <typename Client>
  void failedSnapshot(Client& client, std::uint64_t revision) {
    const GraphicsHeader snapshot{.pane_id = 1, .revision = revision};

    deliver(client, GraphicsSnapshot{.header = snapshot, .phase = SnapshotPhase::begin});
    constexpr auto image_count = GraphicsStore<telar::ConcurrentMemory>::image_capacity + 1;

    for (std::uint32_t id = 1; id <= image_count; ++id) {
      deliver(client, GraphicsImage{.header = snapshot, .image = description(id)});
    }

    deliver(client, GraphicsSnapshot{.header = snapshot, .phase = SnapshotPhase::end});
  }

  void repeatedOversizedSnapshotsUseThePaneBudget() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport, &Clock::nowNanoseconds};

    openFirstPane(client, transport);
    constexpr std::uint64_t failed_snapshots = 4;

    for (std::uint64_t revision = 1; revision <= failed_snapshots; ++revision) {
      failedSnapshot(client, revision);
    }

    constexpr std::size_t expected_resyncs = 3;

    check(transport.count(ClientTag::request_graphics_snapshot) == expected_resyncs, "a fourth oversized snapshot must wait instead of creating an unbounded retry loop");
    check(application::notifications::center(client).items().size() == 1, "one pause must publish one notice across repeated failed snapshots");
    check(client.ready(), "a graphics pause must preserve the runtime link and terminal input");
  }

  void pausedDeletesReturnCreditAndACompleteSnapshotClearsTheMarker() {
    Clock::now_ns = 0;
    SystemAllocator memory;
    RecoveryTransport transport;
    TestSession client{memory, transport, &Clock::nowNanoseconds};

    openFirstPane(client, transport);
    deliver(client, PaneForeground{.pane_id = 1, .name = "nvim"});
    failedSnapshot(client, 1);
    check(application::terminal::graphics::paused(client, 1), "the marker must start with the first failed transfer");
    const auto& notice = application::notifications::center(client).items().front();

    check(notice.title.view() == "Images paused in pane 1: nvim", "a pause must name the pane by its displayed index and foreground");
    check(notice.message.view() == "GraphicsImageLimitExceeded: limit reached" && notice.level == NotificationLevel::warning, "the pause must describe the actual limit as a warning");
    check(notice.target.kind == NotificationTarget::Kind::pane && notice.target.id == 1, "a pause notice must focus its pane when clicked");
    const auto report = transport.last<ReportLimit>();

    check(report.hits == 1 && report.reach.name == "GraphicsImageLimitExceeded" && report.reach.route == "runtime_message", "the runtime must receive the first limit reach");

    deliver(client, GraphicsDeleteImage{.header = header, .key = description(1).key});
    check(transport.last<GraphicsCredit>().bytes == pixel_bytes, "deletes must still release credits while the image stream is paused");
    constexpr GraphicsHeader resumed{.pane_id = 1, .revision = 2};

    deliver(client, GraphicsSnapshot{.header = resumed, .phase = SnapshotPhase::begin});
    check(application::terminal::graphics::paused(client, 1), "a snapshot begin alone must retain the paused marker");
    const auto image = description(1, 2);

    deliver(client, GraphicsImage{.header = resumed, .image = image});
    deliver(client, GraphicsImageChunk{.header = resumed, .key = image.key, .bytes = pixels});
    deliver(client, GraphicsSnapshot{.header = resumed, .phase = SnapshotPhase::end});
    check(!application::terminal::graphics::paused(client, 1) && !application::terminal::graphics::resumeDeadline(client), "only an applied complete snapshot ends the pause");
  }

  void resumeDeadlineAndFocusKeepTheBackoff() {
    Clock::now_ns = 0;
    SystemAllocator memory;
    RecoveryTransport transport;
    TestSession client{memory, transport, &Clock::nowNanoseconds};

    openFirstPane(client, transport);
    for (std::uint64_t revision = 1; revision <= 4; ++revision) {
      failedSnapshot(client, revision);
    }

    constexpr auto window = GraphicsPauseLimits::healthy_window_ns;

    check(application::terminal::graphics::resumeDeadline(client) == window, "the first exhausted window must wait sixty awake seconds");
    Clock::now_ns = window - 1;
    application::terminal::graphics::resume(client);
    check(transport.count(ClientTag::request_graphics_snapshot) == 3, "a retry must not run before its deadline");
    Clock::now_ns = window;
    application::terminal::graphics::resume(client);
    check(transport.count(ClientTag::request_graphics_snapshot) == 4 && !application::terminal::graphics::resumeDeadline(client), "a timer must request recovery without receiving a runtime message");
    constexpr std::uint64_t first_retry_revision = 5;
    constexpr std::uint64_t last_retry_revision = 7;

    for (auto revision = first_retry_revision; revision <= last_retry_revision; ++revision) {
      failedSnapshot(client, revision);
    }

    check(application::terminal::graphics::resumeDeadline(client) == 3 * window, "the next exhausted window must double its delay");
    Clock::now_ns = 2 * window;
    application::workbench::focusPane(client, 1);
    check(transport.count(ClientTag::request_graphics_snapshot) == last_retry_revision && !application::terminal::graphics::resumeDeadline(client), "focusing a pane must accelerate a doubled wait after one healthy window");
  }

  void failedReportsRetainHitsAndNeverDropTheLink() {
    Clock::now_ns = 0;
    SystemAllocator memory;
    RecoveryTransport transport;
    TestSession client{memory, transport, &Clock::nowNanoseconds};

    openFirstPane(client, transport);
    transport.reject_reports = true;
    failedSnapshot(client, 1);
    check(client.ready() && transport.recovery_reason.empty(), "a best effort diagnostic report must not disconnect the terminal");
    transport.reject_reports = false;
    failedSnapshot(client, 2);
    check(transport.last<ReportLimit>().hits == 2, "the next report must recover hits from an unsent report");
    failedSnapshot(client, 3);
    check(transport.count(ClientTag::report_limit) == 1, "a delivered limit report must be paced independently of snapshot retries");
    Clock::now_ns = features::notifications::LimitNotices::report_interval_ms * NotificationInput::nanoseconds_per_millisecond;
    failedSnapshot(client, 4);
    check(transport.last<ReportLimit>().hits == 2 && transport.count(ClientTag::report_limit) == 2, "the next reporting interval must include the accumulated reaches");
  }

  void criticalDeliveryAndMalformedImagesRecoverTheRuntimeLink() {
    for (const bool malformed : {false, true}) {
      Clock::now_ns = 0;
      SystemAllocator memory;
      RecoveryTransport transport;
      TestSession client{memory, transport, &Clock::nowNanoseconds};

      openFirstPane(client, transport);
      transport.reject_graphics = !malformed;
      bool failed = false;

      try {
        if (malformed) {
          deliver(client, GraphicsImageChunk{.header = header, .key = description(1).key, .bytes = pixels});
        } else {
          failedSnapshot(client, 1);
        }
      } catch (const EncodingError&) {
        failed = true;
      }

      check(failed && !client.ready() && !transport.recovery_reason.empty(), "a malformed transfer or undeliverable resync must recover the link instead of leaving a wrong connected replica");
    }
  }

  void snapshotMismatchRequestsRecoveryWithoutALimitNotice() {
    Clock::now_ns = 0;
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport, &Clock::nowNanoseconds};

    openFirstPane(client, transport);
    deliver(client, GraphicsSnapshot{.header = header, .phase = SnapshotPhase::begin});
    deliver(client, GraphicsImage{.header = {.pane_id = 1, .revision = 2}, .image = description(1)});
    check(client.ready() && transport.count(ClientTag::request_graphics_snapshot) == 1, "a revision mismatch must request a graphics snapshot");
    check(!application::terminal::graphics::paused(client, 1) && application::notifications::center(client).items().empty(), "revision drift must not be reported as a resource limit");
  }

  const telar::testing::Case case_replacement_does_not_consume_another_logical_image_slot{"graphics_recovery.replacement_does_not_consume_another_logical_image_slot", replacementDoesNotConsumeAnotherLogicalImageSlot};
  const telar::testing::Case case_window_limit_uses_the_shared_report_and_notification_ledger{"graphics_recovery.window_limit_uses_the_shared_report_and_notification_ledger", windowLimitUsesTheSharedReportAndNotificationLedger};
  const telar::testing::Case case_superseded_incomplete_headers_stay_within_one_image_allocation{"graphics_recovery.superseded_incomplete_headers_stay_within_one_image_allocation", supersededIncompleteHeadersStayWithinOneImageAllocation};
  const telar::testing::Case case_virtual_placement_identity_does_not_depend_on_its_image{"graphics_recovery.virtual_placement_identity_does_not_depend_on_its_image", virtualPlacementIdentityDoesNotDependOnItsImage};
  const telar::testing::Case case_repeated_oversized_snapshots_use_the_pane_budget{"graphics_recovery.repeated_oversized_snapshots_use_the_pane_budget", repeatedOversizedSnapshotsUseThePaneBudget};
  const telar::testing::Case case_paused_deletes_return_credit_and_a_complete_snapshot_clears_the_marker{"graphics_recovery.paused_deletes_return_credit_and_a_complete_snapshot_clears_the_marker", pausedDeletesReturnCreditAndACompleteSnapshotClearsTheMarker};
  const telar::testing::Case case_resume_deadline_and_focus_keep_the_backoff{"graphics_recovery.resume_deadline_and_focus_keep_the_backoff", resumeDeadlineAndFocusKeepTheBackoff};
  const telar::testing::Case case_failed_reports_retain_hits_and_never_drop_the_link{"graphics_recovery.failed_reports_retain_hits_and_never_drop_the_link", failedReportsRetainHitsAndNeverDropTheLink};
  const telar::testing::Case case_critical_delivery_and_malformed_images_recover_the_runtime_link{"graphics_recovery.critical_delivery_and_malformed_images_recover_the_runtime_link", criticalDeliveryAndMalformedImagesRecoverTheRuntimeLink};
  const telar::testing::Case case_snapshot_mismatch_requests_recovery_without_a_limit_notice{"graphics_recovery.snapshot_mismatch_requests_recovery_without_a_limit_notice", snapshotMismatchRequestsRecoveryWithoutALimitNotice};

}
