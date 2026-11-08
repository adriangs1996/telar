#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "application.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <cstddef>
#include <cstdint>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <array>
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include <algorithm>
#include <optional>
#include <span>
#include <filesystem>
#include <string>
#include <vector>
#include "../platform/environment.hpp"
#include <QByteArray>
#include <QFileInfo>
#include <QtCore/qstringfwd.h>
#include <QString>
#include <QtConcurrentRun>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <exception>
#include <utility>

#include "platform/environment.hpp"


import telar.gui.links.path_expansion;
import telar.gui.machines.picker;
import telar.gui.paths.label;

namespace telar::gui::qt {

namespace {

constexpr QLatin1StringView new_workspace{"new-workspace"};

std::string_view view(const QByteArray &bytes) noexcept {
  return {bytes.constData(), static_cast<std::size_t>(bytes.size())};
}

}

QVariantMap Application::workspaceFormState() const {
  QStringList entries;
  if (workspaceListingCurrent()) {
    for (const auto &name : workspace_form_.completion.entries) {
      entries.append(QString::fromStdString(name));
    }
  }

  return {
      {QStringLiteral("entries"), entries},
      {QStringLiteral("selection"), static_cast<int>(workspace_form_.selection)},
      {QStringLiteral("confirmCreate"), workspace_form_.confirm_create},
      {QStringLiteral("completes"), machines_.active() == Machines::local_slot},
  };
}

void Application::resetWorkspaceForm() {
  workspace_form_ = {};
  emit workspaceFormChanged();
}

// Folders are listed only on this computer: a remote machine's directories
// are not here to list or to check.
void Application::editWorkspaceDirectory(const QString &text) {
  if (dialog_ != new_workspace) {
    return;
  }

  workspace_form_.confirm_create = false;
  workspace_form_.selection = 0;
  workspace_form_.wanted.clear();
  if (machines_.active() == Machines::local_slot) {
    try {
      const auto typed = text.toUtf8();
      const auto expanded = expandWorkspaceDirectory(text).toUtf8();
      workspace_form_.wanted = QString::fromStdString(DirectoryCompletion::query({.text = view(typed), .expanded = view(expanded)}));
    } catch (const std::exception &) {
      // An unexpandable path lists nothing; submitting it reports why.
      workspace_form_.wanted.clear();
    }
  }

  if (!workspaceListingCurrent()) {
    listWorkspaceDirectory();
  }

  emit workspaceFormChanged();
}

void Application::moveWorkspaceDirectory(int delta) {
  const auto count = workspaceListingCurrent() ? workspace_form_.completion.entries.size() : 0;
  if (dialog_ != new_workspace || count == 0) {
    return;
  }

  const auto selected = static_cast<long long>(workspace_form_.selection) + delta;
  workspace_form_.selection = static_cast<std::size_t>(std::clamp(selected, 0LL, static_cast<long long>(count - 1)));
  emit workspaceFormChanged();
}

QString Application::acceptWorkspaceDirectory() {
  if (dialog_ != new_workspace || !workspaceListingCurrent() || workspace_form_.completion.entries.empty()) {
    return {};
  }

  return chooseWorkspaceDirectory(static_cast<int>(workspace_form_.selection));
}

QString Application::chooseWorkspaceDirectory(int index) {
  const auto &entries = workspace_form_.completion.entries;
  if (dialog_ != new_workspace || !workspaceListingCurrent() || index < 0 || static_cast<std::size_t>(index) >= entries.size()) {
    return {};
  }

  return QString::fromStdString(workspace_form_.completion.join(static_cast<std::size_t>(index)));
}

bool Application::workspaceListingCurrent() const {
  return !workspace_form_.wanted.isEmpty() && workspace_form_.wanted == workspace_form_.landed;
}

QString Application::expandWorkspaceDirectory(const QString &text) const {
  const platform::ProcessEnvironment environment;
  const auto *pane = session().focusedPane();
  const std::string_view base = pane == nullptr ? std::string_view{} : std::string_view{pane->cwd};
  const auto typed = text.toUtf8();
  const auto expanded = PathExpansion::expand({.text = view(typed), .base = base}, environment);

  return QString::fromUtf8(expanded.view().data(), static_cast<qsizetype>(expanded.view().size()));
}

void Application::listWorkspaceDirectory() {
  if (workspace_listing_.isRunning() || workspace_form_.wanted.isEmpty()) {
    return;
  }

  workspace_form_.listing = workspace_form_.wanted;
  workspace_listing_.setFuture(QtConcurrent::run([query = workspace_form_.listing.toStdString()] {
    return DirectoryCompletion::list(query);
  }));
}

void Application::landWorkspaceDirectory() {
  auto result = workspace_listing_.result();
  if (dialog_ != new_workspace) {
    return;
  }

  if (result.matched > DirectoryCompletion::maximum_entries) {
    session().reportLimit({.name = "workspace_form.completion_entries", .noun = "directories", .value = DirectoryCompletion::maximum_entries, .requested = result.matched, .route = {}});
    refreshNotifications();
  }

  workspace_form_.completion = std::move(result);
  workspace_form_.landed = workspace_form_.listing;
  workspace_form_.selection = 0;
  if (!workspaceListingCurrent()) {
    listWorkspaceDirectory();
  }

  emit workspaceFormChanged();
}

// Names the workspace after its folder when the name is empty, and asks once
// before creating a folder that does not exist. False keeps the form open.
bool Application::submitWorkspace(const QVariantMap &input) {
  const auto name = input.value(QStringLiteral("text")).toString();
  const auto typed = input.value(QStringLiteral("path")).toString();
  const bool local = machines_.active() == Machines::local_slot;
  QString directory;
  if (!typed.trimmed().isEmpty()) {
    directory = local ? expandWorkspaceDirectory(typed) : typed;
  }

  bool create = false;
  if (local && !directory.isEmpty()) {
    const QFileInfo folder{directory};
    if (folder.exists() && !folder.isDir()) {
      throw std::invalid_argument{"NotADirectory"};
    }

    if (!folder.exists() && !workspace_form_.confirm_create) {
      workspace_form_.confirm_create = true;
      emit workspaceFormChanged();

      return false;
    }

    create = !folder.exists();
  }

  const auto folder = directory.toUtf8();
  const auto folder_name = DirectoryCompletion::basename(view(folder));
  const auto label = name.isEmpty() ? QByteArray{folder_name.data(), static_cast<qsizetype>(folder_name.size())} : name.toUtf8();
  if (label.isEmpty()) {
    return false;
  }

  session().createWorkspace({.name = view(label), .path = view(folder), .create_directory = create});

  return true;
}

}
