module telar.gui.application.session;

import std;
import telar.base.text.utf8;

namespace telar::gui {

  bool Session::graphicsPaused(std::uint64_t pane_id) const noexcept {
    return graphics_pauses_.contains(pane_id);
  }

  std::uint64_t Session::graphicsRecoveryRevision() const noexcept {
    return graphics_pauses_.revision();
  }

  std::optional<std::uint64_t> Session::graphicsResumeDeadline() const noexcept {
    return graphics_pauses_.nextDeadline();
  }

  void Session::resumeGraphics() {
    if (ready_) {
      graphics_pauses_.resumeDue(now_(), [this](std::uint64_t pane_id) {
        requestGraphicsSnapshot(pane_id);
      });
    }
  }

  template <typename Message, typename Source = std::nullptr_t>
  Change Session::applyGraphics(const Message& message, Source source) {
    auto* pane = findPane(message.header.pane_id);
    if (pane == nullptr || !pane->attached) {
      return Change::none;
    }

    bool changed = false;

    try {
      if constexpr (std::same_as<Message, GraphicsSnapshot>) {
        changed = pane->graphics.snapshot(message);
        if (changed) {
          graphics_pauses_.snapshotApplied(pane->id, message.phase, now_());
        }
      } else if constexpr (std::same_as<Message, GraphicsImage>) {
        changed = pane->graphics.image(message);
      } else if constexpr (std::same_as<Message, GraphicsSharedImage>) {
        changed = pane->graphics.sharedImage(message, source);
      } else if constexpr (std::same_as<Message, GraphicsImageChunk>) {
        changed = pane->graphics.chunk(message);
      } else if constexpr (std::same_as<Message, GraphicsPlacementMessage>) {
        changed = pane->graphics.placement(message);
      } else {
        changed = pane->graphics.erase(message);
      }
    } catch (const GraphicsLimitError& error) {
      pauseGraphics(pane->id, error);
    } catch (const GraphicsResyncRequired&) {
      requestGraphicsSnapshot(pane->id);
    }

    const auto credit = pane->graphics.takeCredit();
    if (credit != 0) {
      sendGraphics(GraphicsCredit{pane->id, credit});
    }

    changed_pane_ = pane->id;

    return changed ? Change::terminal : Change::none;
  }

  template <typename Message>
  void Session::sendGraphics(const Message& message) {
    try {
      send(message);
    } catch (const std::exception& error) {
      recoverRuntime(error.what());

      throw;
    }
  }

  void Session::requestGraphicsSnapshot(std::uint64_t pane_id) {
    sendGraphics(RequestGraphicsSnapshot{pane_id});
  }

  void Session::pauseGraphics(std::uint64_t pane_id, const GraphicsLimitError& error) {
    const auto slot = countLimitReach({.name = error.what(), .route = "runtime_message"}).slot;

    graphics_pauses_.pause(pane_id, now_(), [this](std::uint64_t paused_pane) {
      requestGraphicsSnapshot(paused_pane);
    },
        [this, slot](std::uint64_t paused_pane) {
          showGraphicsPause(slot, paused_pane);
        });
  }

  void Session::showGraphicsPause(LimitReports::Slot slot, std::uint64_t pane_id) {
    const auto& row = limit_reports_.row(slot);
    const auto message = LimitReports::describe(row.reach(), row.hits);
    const auto title = graphicsPauseTitle(pane_id);

    publishNotification({.level = NotificationLevel::warning, .target = {.kind = NotificationTarget::Kind::pane, .id = pane_id}, .title = title.view(), .message = message.view(), .link = {}, .duration_ns = limit_notice_duration_ns});
  }

  BoundedText<max_notification_title_bytes> Session::graphicsPauseTitle(std::uint64_t pane_id) const {
    BoundedText<max_notification_title_bytes> title;

    title.append("Images paused");
    const auto* pane = findPane(pane_id);
    const auto* tab = pane == nullptr ? nullptr : findTab(pane->location);
    const auto index = tab == nullptr ? 0 : tab->layout.displayIndex(pane_id);
    if (index != 0) {
      const std::string_view foreground{pane->foreground};
      const auto name = !foreground.empty() && inspectUtf8(foreground) == Utf8Validation::valid ? foreground : "shell";

      title.append(" in pane ");
      title.appendDecimal(static_cast<std::uint16_t>(index));
      title.append(": ");
      title.append(name);
    }

    return title;
  }

  void Session::forgetClosedGraphics() {
    graphics_pauses_.forgetClosed([this](std::uint64_t pane_id) {
      return findPane(pane_id) != nullptr;
    });
  }

  Change Session::apply(const GraphicsSnapshot& message) {
    return applyGraphics(message);
  }

  Change Session::apply(const GraphicsImage& message) {
    return applyGraphics(message);
  }

  bool Session::supportsSharedGraphics() const noexcept {
    return transport_.supportsSharedMemory();
  }

  Change Session::apply(const GraphicsSharedImage& message) {
    if (supportsSharedGraphics()) {
      return applyGraphics(message, transport_.sharedImage(message.name));
    }

    throw EncodingError{"Shared graphics was not negotiated"};
  }

  Change Session::apply(const GraphicsImageChunk& message) {
    return applyGraphics(message);
  }

  Change Session::apply(const GraphicsPlacementMessage& message) {
    return applyGraphics(message);
  }

  Change Session::apply(const GraphicsDeleteImage& message) {
    return applyGraphics(message);
  }

  Change Session::apply(const GraphicsDeletePlacement& message) {
    return applyGraphics(message);
  }

}
