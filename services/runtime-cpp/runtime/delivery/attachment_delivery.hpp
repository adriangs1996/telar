#pragma once

#include "../../diagnostics/trace.hpp"
#include "../../model/runtime_model.hpp"
#include <bit>
#include <sys/wait.h>

namespace telar::runtime {

template <Allocator Memory>
class AttachmentDelivery {
public:
  using Clock = std::chrono::steady_clock;

  explicit AttachmentDelivery(RuntimeModel<Memory> &model, ClientSession<Memory> &client) : model_(model), client_(client) {
    for (const auto &attachment : client.attachments) {
      auto *pane = model.panes.find(attachment->pane_id);
      if (pane != nullptr && !attachment->exit_sent) {
        slots_[attachment->slot] = {attachment.get(), pane, false};
        occupied_ |= std::uint64_t{1} << attachment->slot;
      }
    }
  }

  bool prepare(DeliveryLane lane, Clock::time_point now, std::chrono::nanoseconds &timeout) {
    const auto start = client_.next_attachment;
    auto candidates = std::rotr(occupied_, static_cast<int>(start));
    while (candidates != 0) {
      const auto slot = (start + std::countr_zero(candidates)) % ClientSession<Memory>::attachment_capacity;
      candidates &= candidates - 1;
      const auto &candidate = slots_[slot];
      auto *attachment = candidate.attachment;
      auto *pane = candidate.pane;
      if (prepare(*attachment, *pane, lane, now, timeout)) {
        client_.next_attachment = (slot + 1) % ClientSession<Memory>::attachment_capacity;
        return true;
      }
    }

    return false;
  }

private:
  struct Slot {
    Attachment<Memory> *attachment;
    Pane<Memory> *pane;
    bool cells_current;
  };

  bool prepare(Attachment<Memory> &attachment, Pane<Memory> &pane, DeliveryLane lane, Clock::time_point now, std::chrono::nanoseconds &timeout) {
    const auto &effects = pane.terminal.effects;
    switch (lane) {
    case DeliveryLane::cells:
      return cells(attachment, pane, now, timeout);
    case DeliveryLane::cwd:
      return metadata(attachment.cwd_revision, pane.cwd_revision + 1, PaneCwd{pane.id, pane.cwd});
    case DeliveryLane::foreground:
      return metadata(attachment.foreground_revision, pane.foreground_revision, PaneForeground{pane.id, pane.foreground.view()});
    case DeliveryLane::title:
      return metadata(attachment.title_revision, effects.title_revision, PaneTitle{pane.id, effects.title()});
    case DeliveryLane::progress:
      return metadata(attachment.progress_revision, effects.progress_revision, PaneProgress{pane.id, effects.progress_state, effects.progress_percent});
    case DeliveryLane::exit:
      return exit(attachment, pane);
    case DeliveryLane::graphics:
      return graphics(attachment, pane, timeout);
    default:
      return false;
    }
  }

  template <typename Message>
  bool metadata(std::uint64_t &observed, std::uint64_t revision, const Message &message) {
    if (observed == revision) {
      return false;
    }

    client_.connection.send(message);
    observed = revision;
    return true;
  }

  bool cells(Attachment<Memory> &attachment, Pane<Memory> &pane, Clock::time_point now, std::chrono::nanoseconds &timeout) {
    if (attachment.frames.waitingForAck(pane.terminal.screen)) {
      return false;
    }

    const bool snapshot = attachment.frames.needsSnapshot(pane.terminal.screen);
    if (!snapshot && !pane.terminal.dirty() && attachment.frames.observedRevision() == pane.terminal.screen.revision) {
      slots_[attachment.slot].cells_current = true;
      return false;
    }

    attachment.pacer.configure(client_.frame_interval);
    if (pane.last_input) {
      attachment.pacer.noteInput(*pane.last_input);
    }

    const auto deadline = attachment.pacer.deadline(now);
    if (!snapshot && !pane.output_closed && deadline && now < *deadline) {
      timeout = std::min(timeout, std::chrono::duration_cast<std::chrono::nanoseconds>(*deadline - now));
      return false;
    }

    if (pane.terminal.mode(GHOSTTY_MODE_SYNC_OUTPUT)) {
      if (pane.sync_started == Clock::time_point{}) {
        pane.sync_started = now;
      }

      const auto release = pane.sync_started + std::chrono::seconds{1};
      if (now < release) {
        timeout = std::min(timeout, std::chrono::duration_cast<std::chrono::nanoseconds>(release - now));
        return false;
      }
    } else {
      pane.sync_started = {};
    }

    TELAR_TRACE("runtime.publishFrame");
    if (attachment.viewport) {
      pane.terminal.scrollTo(*attachment.viewport);
    }

    pane.terminal.refresh();
    TELAR_DIAGNOSTIC(attachment.frames.setCounters(model_.metrics.frames));
    const auto payload = attachment.frames.prepare(pane.terminal.screen);
    slots_[attachment.slot].cells_current = true;
    if (attachment.viewport) {
      pane.terminal.scrollToBottom();
    }

    if (!snapshot) {
      attachment.pacer.record(now, deadline);
    }
    if (payload.empty()) {
      return false;
    }

    client_.connection.sendPayload(payload);
    return true;
  }

  bool exit(Attachment<Memory> &attachment, const Pane<Memory> &pane) {
    if (!pane.output_closed || !pane.exit_status || !pane.media->idle() || attachment.frames.waitingForAck() || !slots_[attachment.slot].cells_current) {
      return false;
    }

    const auto status = *pane.exit_status;
    client_.connection.send(PaneExited{
        .pane_id = pane.id,
        .kind = WIFEXITED(status) ? ExitKind::exited : ExitKind::signaled,
        .value = static_cast<std::uint32_t>(WIFEXITED(status) ? WEXITSTATUS(status) : WTERMSIG(status)),
    });
    attachment.exit_sent = true;
    client_.completing_exit = pane.id;
    return true;
  }

  bool graphics(Attachment<Memory> &attachment, Pane<Memory> &pane, std::chrono::nanoseconds &timeout) {
    TELAR_DIAGNOSTIC(attachment.graphics.bindCounters(model_.metrics.graphics));
    const auto queued = client_.connection.queuedBytes();
    if (pane.media->busy()) {
      if (attachment.graphics.advanceTransfer(client_.connection)) {
        timeout = std::chrono::nanoseconds::zero();
      }
      return client_.connection.queuedBytes() != queued;
    }

    auto *terminal = pane.media->terminal();
    try {
      const bool pending = terminal == nullptr ? attachment.graphics.publish(client_.connection, pane.terminal.graphics) : attachment.graphics.publish(client_.connection, terminal->graphics);
      if (pending) {
        timeout = std::chrono::nanoseconds::zero();
      }
    } catch (const std::bad_alloc &) {
      attachment.graphics.abandon(terminal == nullptr ? pane.terminal.graphics.revision() : terminal->graphics.revision());
    }
    return client_.connection.queuedBytes() != queued;
  }

  RuntimeModel<Memory> &model_;
  ClientSession<Memory> &client_;
  std::array<Slot, ClientSession<Memory>::attachment_capacity> slots_;
  std::uint64_t occupied_ = 0;
};

template <Allocator Memory>
AttachmentDelivery(RuntimeModel<Memory> &model, ClientSession<Memory> &client) -> AttachmentDelivery<Memory>;

}
