#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "workspace_form_controller.hpp"
#include "ui/foundation/process/environment.hpp"
#include <QByteArray>
#include <QFileInfo>
#include <QStringList>
#include <QtConcurrentRun>
#include <algorithm>
#include <exception>
#include <stdexcept>
#include <string_view>
#include <utility>

import telar.gui.application;

namespace telar::gui::qt {

  namespace {

    std::string_view view(const QByteArray& bytes) noexcept {
      return {bytes.constData(), static_cast<std::size_t>(bytes.size())};
    }

  }

  WorkspaceFormController::WorkspaceFormController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {
    connect(&lister_, &QFutureWatcher<DirectoryCompletion>::finished, this, &WorkspaceFormController::land);
  }

  bool WorkspaceFormController::isOpen() const noexcept {
    return store_.dialog().kind == Store::Dialog::new_workspace;
  }

  bool WorkspaceFormController::local() const noexcept {
    return store_.machines().active() == application::machines::Machines::local_slot;
  }

  QVariantMap WorkspaceFormController::state() const {
    QStringList entries;

    if (listingCurrent()) {
      for (const auto& name : completion_.entries) {
        entries.append(QString::fromStdString(name));
      }
    }

    return {
        {QStringLiteral("entries"), entries},
        {QStringLiteral("selection"), static_cast<int>(selection_)},
        {QStringLiteral("confirmCreate"), confirm_create_},
        {QStringLiteral("completes"), local()},
    };
  }

  void WorkspaceFormController::reset() {
    wanted_.clear();
    listing_.clear();
    landed_.clear();
    completion_ = {};
    selection_ = 0;
    confirm_create_ = false;
    emit changed();
  }

  // Folders are listed only on this computer: a remote machine's directories are not here to list
  // or to check.
  void WorkspaceFormController::edit(const QString& text) {
    if (!isOpen()) {
      return;
    }

    confirm_create_ = false;
    selection_ = 0;
    wanted_.clear();
    if (local()) {
      try {
        const auto typed = text.toUtf8();
        const auto expanded = expand(text).toUtf8();

        wanted_ = QString::fromStdString(DirectoryCompletion::query({.text = view(typed), .expanded = view(expanded)}));
      } catch (const std::exception&) {
        // An unexpandable path lists nothing; submitting it reports why.
        wanted_.clear();
      }
    }

    if (!listingCurrent()) {
      list();
    }

    emit changed();
  }

  void WorkspaceFormController::move(int delta) {
    const auto count = listingCurrent() ? completion_.entries.size() : 0;
    if (!isOpen() || count == 0) {
      return;
    }

    const auto selected = static_cast<long long>(selection_) + delta;

    selection_ = static_cast<std::size_t>(std::clamp(selected, 0LL, static_cast<long long>(count - 1)));
    emit changed();
  }

  QString WorkspaceFormController::accept() {
    if (!isOpen() || !listingCurrent() || completion_.entries.empty()) {
      return {};
    }

    return choose(static_cast<int>(selection_));
  }

  QString WorkspaceFormController::choose(int index) {
    const auto& entries = completion_.entries;
    if (!isOpen() || !listingCurrent() || index < 0 || static_cast<std::size_t>(index) >= entries.size()) {
      return {};
    }

    return QString::fromStdString(completion_.join(static_cast<std::size_t>(index)));
  }

  bool WorkspaceFormController::listingCurrent() const {
    return !wanted_.isEmpty() && wanted_ == landed_;
  }

  QString WorkspaceFormController::expand(const QString& text) const {
    const ProcessEnvironment environment;
    const auto* pane = store_.session().focusedPane();
    const std::string_view base = pane == nullptr ? std::string_view{} : std::string_view{pane->cwd};
    const auto typed = text.toUtf8();
    const auto expanded = application::terminal::links::PathExpansion::expand({.text = view(typed), .base = base}, environment);

    return QString::fromUtf8(expanded.view().data(), static_cast<qsizetype>(expanded.view().size()));
  }

  void WorkspaceFormController::list() {
    if (lister_.isRunning() || wanted_.isEmpty()) {
      return;
    }

    listing_ = wanted_;
    lister_.setFuture(QtConcurrent::run([query = listing_.toStdString()] {
      return DirectoryCompletion::list(query);
    }));
  }

  void WorkspaceFormController::land() {
    auto result = lister_.result();

    if (!isOpen()) {
      return;
    }

    if (result.matched > DirectoryCompletion::maximum_entries) {
      application::notifications::reportLimit(store_.session(), {.name = "workspace_form.completion_entries", .noun = "directories", .value = DirectoryCompletion::maximum_entries, .requested = result.matched, .route = {}});
      store_.commit();
    }

    completion_ = std::move(result);
    landed_ = listing_;
    selection_ = 0;
    if (!listingCurrent()) {
      list();
    }

    emit changed();
  }

  bool WorkspaceFormController::submit(const QVariantMap& input) {
    const auto name = input.value(QStringLiteral("text")).toString();
    const auto typed = input.value(QStringLiteral("path")).toString();
    const bool on_this_computer = local();
    QString directory;

    if (!typed.trimmed().isEmpty()) {
      directory = on_this_computer ? expand(typed) : typed;
    }

    bool create = false;

    if (on_this_computer && !directory.isEmpty()) {
      const QFileInfo folder{directory};
      if (folder.exists() && !folder.isDir()) {
        throw std::invalid_argument{"NotADirectory"};
      }

      if (!folder.exists() && !confirm_create_) {
        confirm_create_ = true;
        emit changed();

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

    application::workbench::createWorkspace(store_.session(), {.name = view(label), .path = view(folder), .create_directory = create});

    return true;
  }

}
