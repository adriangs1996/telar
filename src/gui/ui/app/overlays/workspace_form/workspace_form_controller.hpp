#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/store/store.hpp"
#include <QFutureWatcher>
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstddef>

#pragma once

import telar.gui.foundation.system;

namespace telar::gui::qt {

  // The new workspace form: the folders that complete what is typed in its directory field, which
  // one is selected, and whether submitting will create a missing folder.
  //
  // Folders are listed only on this computer, one listing at a time on a worker; the query typed
  // meanwhile starts once the running one lands. It reads the store and creates the workspace in
  // the active session; the window opens and closes the form.
  class WorkspaceFormController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(WorkspaceFormController)
    QML_UNCREATABLE("Use the window's workspace form")
    Q_PROPERTY(QVariantMap state READ state NOTIFY changed)

  public:
    explicit WorkspaceFormController(Store& store, QObject* parent = nullptr);
    ~WorkspaceFormController() override = default;
    WorkspaceFormController(const WorkspaceFormController&) = delete;
    WorkspaceFormController& operator=(const WorkspaceFormController&) = delete;
    WorkspaceFormController(WorkspaceFormController&&) = delete;
    WorkspaceFormController& operator=(WorkspaceFormController&&) = delete;

    [[nodiscard]] QVariantMap state() const;
    Q_INVOKABLE void edit(const QString& text);
    Q_INVOKABLE void move(int delta);
    // The selected folder joined to what was typed, or empty when none is listed.
    Q_INVOKABLE QString accept();
    Q_INVOKABLE QString choose(int index);

    // The form opened or closed: nothing typed or listed belongs to the next one.
    void reset();
    // Creates the workspace, named after its folder when the name is empty, and asks once before
    // creating a folder that does not exist. False keeps the form open; it throws what the
    // session rejects.
    bool submit(const QVariantMap& input);

  signals:
    void changed();

  private:
    [[nodiscard]] bool isOpen() const noexcept;
    [[nodiscard]] bool local() const noexcept;
    [[nodiscard]] bool listingCurrent() const;
    [[nodiscard]] QString expand(const QString& text) const;
    void list();
    void land();

    Store& store_;
    QString wanted_;
    QString listing_;
    QString landed_;
    DirectoryCompletion completion_;
    std::size_t selection_ = 0;
    bool confirm_create_ = false;
    QFutureWatcher<DirectoryCompletion> lister_;
  };

}
