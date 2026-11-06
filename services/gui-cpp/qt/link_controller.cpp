#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "application.hpp"
#include "external_link_opener.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "../terminal/cell_position.hpp"
#include "../terminal/screen.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <limits>
#include <array>
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include "machine_client.hpp"
#include "machine_client_key.hpp"
#include "../platform/environment.hpp"
#include "projection.hpp"
#include <QString>
#include <QtCore/qtmetamacros.h>
#include <exception>

#include "platform/environment.hpp"
#include "terminal/cell_position.hpp"


import telar.gui.links.cell_links;
import telar.gui.links.path_expansion;

namespace telar::gui::qt {

bool Application::openLink(const LinkTarget &target, std::optional<std::uint64_t> source_id) {
  try {
    if (target.scheme() == LinkScheme::file || target.scheme() == LinkScheme::path) {
      const platform::ProcessEnvironment environment;
      const auto configured = configuration().editor.view();
      const auto executable = configured.empty() ? environment("EDITOR").value_or(std::string_view{}) : configured;
      session().openFile(FilePath::parse(target), executable, environment, source_id);
    } else {
      link_opener_.request(target, clientAt(machines_.active()).key);
    }
  } catch (const std::exception &error) {
    emit notification(QStringLiteral("Could not open link: ") + toQString(error.what()));

    return false;
  }

  return true;
}

void Application::openCopyLink(std::uint64_t pane_id, CellPosition point) {
  const auto *pane = session().findPane(pane_id);
  if (pane == nullptr) {
    return;
  }

  const auto found = CellLinks::text(pane->screen, point);
  if (found) {
    static_cast<void>(openLink(found->target, pane_id));
  }
}

void Application::linkOpeningFinished(MachineClientKey source, std::optional<LinkOpeningFailure> failure) {
  auto *client = findClient(source);
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

  client->session.publishNotification({.title = "Telar", .message = message, .link = {}});
  if (source.machine.slot == machines_.active()) {
    refreshNotifications();
  }
}

}
