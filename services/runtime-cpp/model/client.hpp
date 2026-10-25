#pragma once

#include "../agents/reporter_state.hpp"
#include "../graphics/synchronizer.hpp"
#include "../platform/descent_probe.hpp"
#include "../platform/process_inspector.hpp"
#include "../terminal/frame_pacer.hpp"
#include "../terminal/frame_sync.hpp"
#include "../terminal/text_search.hpp"
#include "../transport/connection.hpp"
#include "client_role.hpp"
#include "pending_clipboard.hpp"
#include <bit>
#include <optional>

namespace telar::runtime {

template <Allocator Memory>
struct Attachment {
  explicit Attachment(Memory &memory, GraphicsCreditBudget &budget, std::uint64_t pane, std::shared_ptr<PaneMedia<Memory>> media)
      : pane_id(pane),
        frames(memory, pane),
        graphics(budget, pane, std::move(media)) {}

  std::uint64_t pane_id;
  std::size_t slot = 0;
  FrameSync<Memory> frames;
  GraphicsSynchronizer<Memory> graphics;
  std::optional<std::uint32_t> viewport;
  bool exit_sent = false;
  std::uint64_t title_revision = 1;
  std::uint64_t cwd_revision = 0;
  std::uint64_t clipboard_revision = 0;
  std::uint64_t foreground_revision = 0;
  std::uint64_t progress_revision = 1;
  FramePacer pacer;
};

template <Allocator Memory>
class ClientSession {
public:
  static constexpr std::size_t attachment_capacity = 64;

  struct ForegroundStamp {
    std::uint64_t pane = 0;
    std::uint64_t revision = 0;
  };

  explicit ClientSession(Memory &memory, std::uint64_t identity, FileDescriptor descriptor)
      : id(identity),
        generation(identity),
        connection(memory, std::move(descriptor)),
        attachments(AllocatorRef<Owned<Attachment<Memory>, Memory>, Memory>{memory}),
        clipboard(memory),
        deferred_report(memory) {
    attachments.reserve(attachment_capacity);
  }

  std::size_t availableAttachmentSlot() const {
    std::uint64_t occupied = 0;
    for (const auto &entry : attachments) {
      occupied |= std::uint64_t{1} << entry->slot;
    }

    if (occupied == UINT64_MAX) {
      throw std::bad_alloc{};
    }
    return std::countr_zero(~occupied);
  }

  Attachment<Memory> *attachment(std::uint64_t pane_id) const noexcept {
    for (const auto &entry : attachments) {
      if (entry->pane_id == pane_id) {
        return entry.get();
      }
    }

    return nullptr;
  }

  std::uint64_t id;
  std::uint64_t generation;
  std::uint64_t event_identity = 0;
  std::uint64_t identity = 0;
  GraphicsCreditBudget graphics_credit;
  ClientRole role = ClientRole::undecided;
  std::uint64_t last_input_pane = 0;
  std::uint64_t last_input_sequence = 0;
  std::optional<PendingClientCommand> pending_command;
  std::optional<PendingPaneFocus> pending_focus;
  Connection<Memory> connection;
  Vector<Owned<Attachment<Memory>, Memory>, Memory> attachments;
  PendingClipboard<Memory> clipboard;
  std::size_t next_attachment = 0;
  std::optional<std::uint64_t> completing_exit;
  bool layout_sent = false;
  bool proxy_status_sent = false;
  bool agent_snapshot_requested = false;
  bool subscribed = false;
  bool interactive = false;
  bool shared_graphics = false;
  std::uint64_t editor_source = 0;
  std::uint64_t editor_generation = 0;
  std::optional<ProcessIdentity> peer_identity;
  std::uint64_t agent_revision = 0;
  std::uint64_t metrics_revision = 0;
  std::uint64_t verified_pane = 0;
  std::uint64_t verified_generation = 0;
  ProcessLineage verified_lineage;
  std::optional<DescentCheck> pending_descent;
  bool descent_running = false;
  DeferredReport<Memory> deferred_report;
  unsigned limit_reports = 0;
  std::chrono::steady_clock::time_point limit_report_window{};
  std::optional<std::uint64_t> workspace;
  std::chrono::nanoseconds frame_interval{1'000'000'000 / 60};
  std::uint64_t workspace_revision = 0;
  std::uint64_t agent_workspace_revision = 0;
  std::optional<ResyncRequired> workspace_resync;
  std::array<ForegroundStamp, 256> foregrounds;
  std::optional<TextSearch> search;
  ConfigureTerminalColors colors{};
};

}
