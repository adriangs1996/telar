#include "application.hpp"
#include "external_link_opener.hpp"
#include "links/cell_links.hpp"
#include "links/file_path.hpp"
#include "links/link_target.hpp"
#include "links/link_text.hpp"
#include "platform/environment.hpp"
#include "projection.hpp"
#include "terminal/cell_position.hpp"
#include <QString>
#include <QtCore/qtmetamacros.h>
#include <cstdint>
#include <exception>
#include <optional>
#include <string_view>

namespace telar::gui::qt {

bool Application::openLink(const LinkTarget &target, std::optional<std::uint64_t> source_id) {
  try {
    if (target.scheme() == LinkScheme::file || target.scheme() == LinkScheme::path) {
      const platform::ProcessEnvironment environment;
      const auto configured = configuration().editor.view();
      const auto executable = configured.empty() ? environment("EDITOR").value_or(std::string_view{}) : configured;
      session_.openFile(FilePath::parse(target), executable, environment, source_id);
    } else {
      link_opener_.request(target);
    }
  } catch (const std::exception &error) {
    emit notification(QStringLiteral("Could not open link: ") + toQString(error.what()));

    return false;
  }

  return true;
}

void Application::openCopyLink(std::uint64_t pane_id, CellPosition point) {
  const auto *pane = session_.findPane(pane_id);
  if (pane == nullptr) {
    return;
  }

  const auto found = CellLinks::text(pane->screen, point);
  if (found) {
    static_cast<void>(openLink(found->target, pane_id));
  }
}

void Application::linkOpeningFinished(std::optional<LinkOpeningFailure> failure) {
  if (!failure) {
    return;
  }

  switch (*failure) {
  case LinkOpeningFailure::launch:
    emit notification(QStringLiteral("Could not open link: host opener is unavailable"));
    break;
  case LinkOpeningFailure::process:
    emit notification(QStringLiteral("Could not open link: host opener failed"));
    break;
  case LinkOpeningFailure::timeout:
    emit notification(QStringLiteral("Could not open link: host opener timed out"));
    break;
  case LinkOpeningFailure::output_limit:
    emit notification(QStringLiteral("Could not open link: host opener exceeded its output limit"));
    break;
  }
}

}
