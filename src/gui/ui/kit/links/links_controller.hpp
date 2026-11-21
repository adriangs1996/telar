#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "external_link_opener.hpp"
#include "ui/kit/store/store.hpp"
#include <QByteArray>
#include <QObject>
#include <QProcess>
#include <QString>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>

#pragma once

#include "tbc/view.hpp"

import telar.gui.foundation.terminal;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  // Opens the links the user activates: a file in the configured editor through the active
  // session, anything else with the host's opener, one at a time. A link to a port of another
  // machine, as a development server there prints it, is opened through a port here that the
  // gateway forwards to it.
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
    bool open(const application::terminal::links::LinkTarget& target, ds::Option<std::uint64_t> source_id = {});
    // Opens the link written at a cell of the pane's screen, if any.
    void openAt(std::uint64_t pane_id, CellPosition point);
    // The host's opener finished the link the client `source` asked for.
    void linkOpeningFinished(application::machines::MachineClientKey source, ds::Option<LinkOpeningFailure> failure);

  signals:
    void openingFailed(const QString& message);
    // The active session holds a new notification.
    void notificationPublished();

  private:
    // A port of another machine forwarded here for the links this window opens. The gateway
    // program holds the forward while it runs: it prints the port here once it listens, and
    // ends when the port closes there.
    struct Forward {
      QProcess process;
      QByteArray destination;
      QByteArray output;
      QByteArray errors;
      std::uint16_t remote = 0;
      std::uint16_t local = 0;
      // The link to open once the port is ready, and the client that asked for it.
      ds::Option<application::terminal::links::LinkTarget> pending;
      application::machines::MachineClientKey source{};
    };

    static constexpr std::size_t maximum_forwards = 16;

    // Opens a link to a port of the active machine through a forward; false for any other link.
    bool openForwarded(const application::terminal::links::LinkTarget& target);
    void startForward(std::unique_ptr<Forward>& slot, const application::terminal::links::LinkTarget& target, std::uint16_t port, std::string_view destination);
    void forwardAnswered(Forward& forward);
    void forwardEnded(Forward* ended);

    Store& store_;
    ds::Array<std::unique_ptr<Forward>, maximum_forwards> forwards_;
    tbc::val_self<ExternalLinkOpener<ApplicationLinkHost, LinksController, application::machines::MachineClientKey>> opener_;
  };

}
