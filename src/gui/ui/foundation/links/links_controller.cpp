#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "links_controller.hpp"
#include "platform/environment.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/models/projection.hpp"
#include <exception>
#include <string_view>

import telar.gui.application;

namespace telar::gui::qt {

  LinksController::LinksController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store),
        opener_(*this) {}

  bool LinksController::open(const application::terminal::links::LinkTarget& target, std::optional<std::uint64_t> source_id) {
    try {
      if (target.scheme() == application::terminal::links::LinkScheme::file || target.scheme() == application::terminal::links::LinkScheme::path) {
        const platform::ProcessEnvironment environment;
        const auto configured = store_.session().configuration().editor.view();
        const auto executable = configured.empty() ? environment("EDITOR").value_or(std::string_view{}) : configured;

        application::terminal::links::openFile(store_.session(), application::terminal::links::FilePath::parse(target), executable, environment, source_id);
      } else {
        opener_.request(target, store_.client(store_.machines().active()).key);
      }
    } catch (const std::exception& error) {
      emit openingFailed(QStringLiteral("Could not open link: ") + toQString(error.what()));

      return false;
    }

    return true;
  }

  void LinksController::openAt(std::uint64_t pane_id, CellPosition point) {
    const auto* pane = store_.session().findPane(pane_id);
    if (pane == nullptr) {
      return;
    }

    const auto found = application::terminal::links::CellLinks::text(pane->screen, point);
    if (found) {
      static_cast<void>(open(found->target, pane_id));
    }
  }

  void LinksController::linkOpeningFinished(application::machines::MachineClientKey source, std::optional<LinkOpeningFailure> failure) {
    auto* client = store_.find(source);
    if (client == nullptr || !failure) {
      return;
    }

    std::string_view message;

    switch (*failure) {
    case LinkOpeningFailure::launch:
      message = "Could not open link: host opener is unavailable";
      break;
    case LinkOpeningFailure::process:
      message = "Could not open link: host opener failed";
      break;
    case LinkOpeningFailure::timeout:
      message = "Could not open link: host opener timed out";
      break;
    case LinkOpeningFailure::output_limit:
      message = "Could not open link: host opener exceeded its output limit";
      break;
    }

    application::notifications::publish(client->session, {.title = "Telar", .message = message, .link = {}});
    if (source.machine.slot == store_.machines().active()) {
      emit notificationPublished();
    }
  }

}
