#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "attachment_shelf.hpp"
#include "ui/kit/store/store.hpp"
#include <QKeyEvent>
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <functional>
#include <optional>

#pragma once

import telar.gui.foundation.core;
import telar.gui.foundation.keys;
import telar.gui.foundation.model;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  // The clipboard images pasted into an agent's prompt on this computer: the shelf under the
  // focused pane that lists them, and the modal that shows one.
  //
  // Images are only taken on the local machine, so the shelf follows the local session; it
  // reserves rows under the agent's pane and writes the markers the agent reads. It reads the
  // store and the display the window pushes. The window takes the input away from the panes
  // while the modal is open.
  class AttachmentsController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(AttachmentsController)
    QML_UNCREATABLE("Use the window's attachments")
    Q_PROPERTY(telar::gui::qt::AttachmentShelf* shelf READ shelf CONSTANT)
    Q_PROPERTY(QVariantMap geometry READ geometry NOTIFY geometryChanged)
    Q_PROPERTY(QVariantMap modalGeometry READ modalGeometry NOTIFY geometryChanged)

  public:
    AttachmentsController(Store& store, ApplicationAllocator& memory, QObject* parent = nullptr);
    ~AttachmentsController() override = default;
    AttachmentsController(const AttachmentsController&) = delete;
    AttachmentsController& operator=(const AttachmentsController&) = delete;
    AttachmentsController(AttachmentsController&&) = delete;
    AttachmentsController& operator=(AttachmentsController&&) = delete;

    [[nodiscard]] AttachmentShelf* shelf() noexcept;
    [[nodiscard]] QVariantMap geometry() const;
    [[nodiscard]] QVariantMap modalGeometry() const;
    [[nodiscard]] bool modalOpen() const noexcept;

    // Follows the local session's focused agent: its prompt, and the rows the shelf reserves.
    void synchronize();
    // Notifies the geometries when what they are measured from moved.
    void publishGeometry();
    void setDisplay(const application::window::DisplayMetrics& display);
    // A key the window received while the modal is open belongs to it.
    bool interceptKey(QKeyEvent& event);
    // A key a pane received: Ctrl+V takes the clipboard's image, and editing keys move the
    // markers the shelf tracks.
    void key(std::uint64_t pane_id, const TerminalKey& key);
    // The local pane drew a frame: the markers the agent reads are read again from it.
    void reconcileFrame(std::uint64_t pane_id);

  signals:
    void geometryChanged();
    // The shelf or its modal changed what it shows.
    void changed();
    // The modal opened or closed; while it is open the panes take no input.
    void modalChanged(bool open);
    void failed(const QString& message);

  private:
    // What the geometries are measured from.
    struct Inputs {
      WorkbenchGeometry host;
      Rect terminal;
      CellRectangle reserved;
      double density = 1;
      bool shelf = false;

      bool operator==(const Inputs& other) const {
        return host == other.host && terminal == other.terminal && reserved == other.reserved && std::equal_to<>{}(density, other.density) && shelf == other.shelf;
      }
    };

    void shelfChanged();
    void dismiss(std::uint64_t identity);

    Store& store_;
    AttachmentShelf shelf_;
    bool modal_open_ = false;
    ds::Option<Inputs> published_;
    application::window::DisplayMetrics display_{};
  };

}
