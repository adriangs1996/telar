#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/store/store.hpp"
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <concepts>
#include <cstddef>
#include <exception>

#pragma once

import telar.gui.application;

namespace telar::gui::qt {

  // The path picker: what is typed, the paths the active session listed for it, which one is
  // selected, and where the picker is drawn, as a dialog under the focused pane's cursor or as
  // rows of its prompt line.
  //
  // It reads the store and the display the window pushes, and asks the session to list, descend
  // and insert. The window opens the picker; inserting a path asks it to close.
  class PathPickerController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(PathPickerController)
    QML_UNCREATABLE("Use the window's path picker")
    Q_PROPERTY(QVariantMap state READ state NOTIFY changed)
    Q_PROPERTY(QVariantMap geometry READ geometry NOTIFY geometryChanged)

  public:
    explicit PathPickerController(Store& store, QObject* parent = nullptr);
    ~PathPickerController() override = default;
    PathPickerController(const PathPickerController&) = delete;
    PathPickerController& operator=(const PathPickerController&) = delete;
    PathPickerController(PathPickerController&&) = delete;
    PathPickerController& operator=(PathPickerController&&) = delete;

    [[nodiscard]] QVariantMap state() const;
    // Not const: arranging the layout fills its placements.
    [[nodiscard]] QVariantMap geometry();
    // The paths from `first` on, at most `count`, cut to `columns` cells, for the prompt line's rows.
    Q_INVOKABLE [[nodiscard]] QVariantList rows(int columns, int first, int count) const;
    Q_INVOKABLE void search(const QString& text);
    Q_INVOKABLE void reportQueryLimit(qulonglong requested_bytes);
    Q_INVOKABLE void move(int delta);
    Q_INVOKABLE void descend();
    Q_INVOKABLE void ascend();
    Q_INVOKABLE void insert(bool absolute);
    Q_INVOKABLE void activate(const QVariantMap& choice);

    // Starts listing from the path under the cursor; false when the session cannot.
    bool open();
    // The session listed paths: the selection stays within them.
    void refresh();
    // The workbench or a pane moved under the picker.
    void publishGeometry();
    void setDisplay(const application::window::DisplayMetrics& display);

  signals:
    void changed();
    void geometryChanged();
    void closeRequested();
    void failed(const QString& message);

  private:
    [[nodiscard]] bool isOpen() const noexcept;
    [[nodiscard]] application::paths::PathPickerPlacement placement();

    // Runs a user's mutation of the session and commits it to the store.
    template <std::invocable Mutation>
    void interact(Mutation mutate) {
      store_.interact(mutate, [this](const std::exception& error) {
        emit failed(QString::fromUtf8(error.what()));
      });
    }

    Store& store_;
    QString query_;
    std::size_t selection_ = 0;
    application::window::DisplayMetrics display_{};
  };

}
