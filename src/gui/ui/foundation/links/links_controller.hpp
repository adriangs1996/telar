#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "external_link_opener.hpp"
#include "ui/foundation/store/store.hpp"
#include <QObject>
#include <QString>
#include <cstdint>
#include <optional>

#pragma once

#include "tbc/view.hpp"

import telar.gui.foundation.terminal;
import telar.gui.application;

namespace telar::gui::qt {

  // Opens the links the user activates: a file in the configured editor through the active
  // session, anything else with the host's opener, one at a time.
  //
  // It reads the store. A link that cannot be opened becomes a notification: the window shows the
  // message, or the session that asked for the link holds it.
  class LinksController final : public QObject {
    Q_OBJECT

  public:
    explicit LinksController(Store& store, QObject* parent = nullptr);
    ~LinksController() override = default;
    LinksController(const LinksController&) = delete;
    LinksController& operator=(const LinksController&) = delete;
    LinksController(LinksController&&) = delete;
    LinksController& operator=(LinksController&&) = delete;

    // A file link opens relative to the pane `source_id` when one is given. False when it could
    // not be opened.
    bool open(const application::terminal::links::LinkTarget& target, std::optional<std::uint64_t> source_id = {});
    // Opens the link written at a cell of the pane's screen, if any.
    void openAt(std::uint64_t pane_id, CellPosition point);
    // The host's opener finished the link the client `source` asked for.
    void linkOpeningFinished(application::machines::MachineClientKey source, std::optional<LinkOpeningFailure> failure);

  signals:
    void openingFailed(const QString& message);
    // The active session holds a new notification.
    void notificationPublished();

  private:
    Store& store_;
    tbc::view<ExternalLinkOpener<ApplicationLinkHost, LinksController, application::machines::MachineClientKey>, tbc::lt::self> opener_;
  };

}
