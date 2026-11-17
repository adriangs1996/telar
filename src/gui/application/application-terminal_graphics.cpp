module telar.gui.application;

import std;

import :access;
import telar.base.text.utf8;
import telar.gui.features.terminal.graphics;
import telar.gui.foundation.text;
import telar.wire.graphics;
import telar.wire.vocabulary;

namespace telar::gui::application::terminal::graphics {

  namespace {

    namespace feature = features::terminal::graphics;

    // A graphics message the transport refuses means the connection is lost: the session
    // recovers it before the error reaches the caller.
    template <typename Message>
    void send(Session& session, const Message& message) {
      try {
        Access::send(session, message);
      } catch (const std::exception& error) {
        Access::recoverRuntime(session, error.what());

        throw;
      }
    }

    BoundedText<max_notification_title_bytes> pauseTitle(const Session& session, std::uint64_t pane_id) {
      BoundedText<max_notification_title_bytes> title;

      title.append("Images paused");
      const auto* pane = session.findPane(pane_id);
      const auto* tab = pane == nullptr ? nullptr : Access::findTab(session, pane->location);
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

    void showPause(Session& session, LimitReports::Slot slot, std::uint64_t pane_id) {
      const auto& row = Access::limitReports(session).row(slot);
      const auto message = LimitReports::describe(row.reach(), row.hits);
      const auto title = pauseTitle(session, pane_id);

      session.publishNotification({.level = NotificationLevel::warning, .target = {.kind = NotificationTarget::Kind::pane, .id = pane_id}, .title = title.view(), .message = message.view(), .link = {}, .duration_ns = Access::limit_notice_duration_ns});
    }

    void pause(Session& session, std::uint64_t pane_id, const feature::GraphicsLimitError& error) {
      const auto slot = Access::countLimitReach(session, {.name = error.what(), .route = "runtime_message"}).slot;

      feature::pause(Access::graphics(session), pane_id, Access::now(session), [&session](std::uint64_t paused_pane) {
        requestSnapshot(session, paused_pane);
      },
          [&session, slot](std::uint64_t paused_pane) {
            showPause(session, slot, paused_pane);
          });
    }

    template <typename Message, typename Source = std::nullptr_t>
    Change apply(Session& session, const Message& message, Source source = nullptr) {
      auto* pane = session.findPane(message.header.pane_id);
      if (pane == nullptr || !pane->attached) {
        return Change::none;
      }

      bool changed = false;

      try {
        if constexpr (std::same_as<Message, GraphicsSnapshot>) {
          changed = pane->graphics.snapshot(message);
          if (changed) {
            feature::receive(Access::graphics(session), pane->id, message.phase, Access::now(session));
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
      } catch (const feature::GraphicsLimitError& error) {
        pause(session, pane->id, error);
      } catch (const feature::GraphicsResyncRequired&) {
        requestSnapshot(session, pane->id);
      }

      const auto credit = pane->graphics.takeCredit();
      if (credit != 0) {
        send(session, GraphicsCredit{pane->id, credit});
      }

      Access::changedPane(session) = pane->id;

      return changed ? Change::terminal : Change::none;
    }

  }

  bool paused(const Session& session, std::uint64_t pane_id) noexcept {
    return feature::paused(Access::graphics(session), pane_id);
  }

  std::uint64_t recoveryRevision(const Session& session) noexcept {
    return feature::revision(Access::graphics(session));
  }

  std::optional<std::uint64_t> resumeDeadline(const Session& session) noexcept {
    return feature::deadline(Access::graphics(session));
  }

  void resume(Session& session) {
    if (session.ready()) {
      feature::resume(Access::graphics(session), Access::now(session), [&session](std::uint64_t pane_id) {
        requestSnapshot(session, pane_id);
      });
    }
  }

  void requestSnapshot(Session& session, std::uint64_t pane_id) {
    send(session, RequestGraphicsSnapshot{pane_id});
  }

  void focus(Session& session, std::uint64_t pane_id) {
    feature::focus(Access::graphics(session), pane_id, Access::now(session), [&session](std::uint64_t paused_pane) {
      requestSnapshot(session, paused_pane);
    });
  }

  void forgetClosed(Session& session) {
    feature::forgetClosed(Access::graphics(session), [&session](std::uint64_t pane_id) {
      return session.findPane(pane_id) != nullptr;
    });
  }

  Change receive(Session& session, const GraphicsSnapshot& message) {
    return apply(session, message);
  }

  Change receive(Session& session, const GraphicsImage& message) {
    return apply(session, message);
  }

  Change receive(Session& session, const GraphicsSharedImage& message) {
    if (Access::sharesImages(session)) {
      return apply(session, message, Access::sharedImage(session, message.name));
    }

    throw EncodingError{"Shared graphics was not negotiated"};
  }

  Change receive(Session& session, const GraphicsImageChunk& message) {
    return apply(session, message);
  }

  Change receive(Session& session, const GraphicsPlacementMessage& message) {
    return apply(session, message);
  }

  Change receive(Session& session, const GraphicsDeleteImage& message) {
    return apply(session, message);
  }

  Change receive(Session& session, const GraphicsDeletePlacement& message) {
    return apply(session, message);
  }

}
