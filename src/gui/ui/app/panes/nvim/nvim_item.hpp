#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "nvim_controller.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "ui/kit/fonts/font_collection.hpp"
#include "ui/kit/fonts/resident_fonts.hpp"
#include "ui/kit/fonts/terminal_font.hpp"
#include "ui/kit/fonts/window_font_catalog.hpp"
#include "ui/kit/models/list_model.hpp"
#include <QKeyEvent>
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QString>
#include <QTimer>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <memory>
#include <span>

#pragma once

import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  // One editor pane: a Neovim the runtime runs, drawn natively. It takes the keys, the pointer
  // and the input method for the pane, gives the editor the cells that fit its view, and tells
  // QML where each grid goes and what Neovim's native surfaces show. Each grid is drawn by an
  // NvimGridItem QML places over it.
  class NvimItem : public QQuickItem {
    Q_OBJECT
    QML_NAMED_ELEMENT(NvimEditor)
    Q_PROPERTY(telar::gui::qt::NvimController* controller READ controller WRITE setController NOTIFY controllerChanged)
    Q_PROPERTY(QString paneId READ paneId WRITE setPaneId NOTIFY paneIdChanged)
    // The grids, one record each: where it is drawn, in this item's coordinates, and what it is.
    Q_PROPERTY(QAbstractItemModel* grids READ grids CONSTANT)
    Q_PROPERTY(qreal cellWidth READ cellWidth NOTIFY metricsChanged)
    Q_PROPERTY(qreal cellHeight READ cellHeight NOTIFY metricsChanged)
    // Where the cursor's cell is, for what follows it: a trail, the input method.
    Q_PROPERTY(QRectF cursorRect READ cursorRect NOTIFY cursorChanged)
    Q_PROPERTY(QString mode READ mode NOTIFY modeChanged)
    // Whether Neovim has drawn its first frame.
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
    // The surfaces Neovim leaves to its UI, each as QML draws it.
    Q_PROPERTY(QVariantList separators READ separators NOTIFY separatorsChanged)
    Q_PROPERTY(QVariantMap cmdline READ cmdline NOTIFY cmdlineChanged)
    Q_PROPERTY(QVariantMap popupMenu READ popupMenu NOTIFY popupMenuChanged)
    Q_PROPERTY(QVariantMap messages READ messages NOTIFY messagesChanged)
    Q_PROPERTY(QVariantMap tabline READ tabline NOTIFY tablineChanged)
    Q_PROPERTY(QVariantMap prompt READ prompt NOTIFY promptChanged)

  public:
    explicit NvimItem(QQuickItem* parent = nullptr);
    ~NvimItem() override;

    NvimItem(const NvimItem&) = delete;
    NvimItem& operator=(const NvimItem&) = delete;
    NvimItem(NvimItem&&) = delete;
    NvimItem& operator=(NvimItem&&) = delete;

    [[nodiscard]] NvimController* controller() const noexcept {
      return controller_;
    }

    void setController(NvimController* controller);

    [[nodiscard]] QString paneId() const {
      return QString::number(pane_id_);
    }

    void setPaneId(const QString& pane_id);

    [[nodiscard]] QAbstractItemModel* grids() noexcept {
      return &grids_;
    }

    [[nodiscard]] qreal cellWidth() const noexcept {
      return font_.cell.width();
    }

    [[nodiscard]] qreal cellHeight() const noexcept {
      return font_.cell.height();
    }

    [[nodiscard]] QRectF cursorRect() const noexcept {
      return cursor_rect_;
    }

    [[nodiscard]] QString mode() const {
      return mode_;
    }

    [[nodiscard]] bool ready() const noexcept {
      return ready_;
    }

    // Where Neovim fills cells with a separator's character between two windows, in pixels:
    // the window draws a line of its own over each.
    [[nodiscard]] QVariantList separators() const {
      return separators_;
    }

    [[nodiscard]] QVariantMap cmdline() const {
      return cmdline_;
    }

    [[nodiscard]] QVariantMap popupMenu() const {
      return popup_menu_;
    }

    [[nodiscard]] QVariantMap messages() const {
      return messages_;
    }

    [[nodiscard]] QVariantMap tabline() const {
      return tabline_;
    }

    [[nodiscard]] QVariantMap prompt() const {
      return prompt_;
    }

    // What the person answered to the prompt the editor shows.
    Q_INVOKABLE void answer(bool accepted, int index = 0, const QString& text = {});
    // Keys in Neovim's notation, from a native surface: a tab that was clicked, a menu item.
    Q_INVOKABLE void send(const QString& keys);
    // Takes an item of the completion menu, counted among all it has, as a click on it does.
    Q_INVOKABLE void chooseMenu(int item);

    // What a grid's item reads to draw: the editor as last shown, and how its cells are drawn.
    [[nodiscard]] const application::nvim::Editor* editorState() const noexcept;
    [[nodiscard]] const application::Pane<Memory>* pane() const noexcept;

    [[nodiscard]] const TerminalFont& font() const noexcept {
      return font_;
    }

    [[nodiscard]] const FontGrid& fontGrid() const noexcept {
      return font_grid_;
    }

    [[nodiscard]] const std::shared_ptr<const FontCollection>& fontCollection() const noexcept {
      return font_collection_;
    }

    [[nodiscard]] std::uint64_t appearance() const noexcept {
      return appearance_;
    }

    [[nodiscard]] bool cursorOn() const noexcept {
      return cursor_on_;
    }

    // Where the input method draws what it composes: at the cursor.
    [[nodiscard]] QVariant inputMethodQuery(Qt::InputMethodQuery query) const override;

    // Asks the window's fonts for what draws `cells` and the editor's own font lacks.
    void requestFonts(std::span<const CellValue> cells);

  signals:
    void controllerChanged();
    void paneIdChanged();
    void metricsChanged();
    void cursorChanged();
    void modeChanged();
    void readyChanged();
    void separatorsChanged();
    void cmdlineChanged();
    void popupMenuChanged();
    void messagesChanged();
    void tablineChanged();
    void promptChanged();
    // A frame was applied, or how cells are drawn changed: each grid's item draws again.
    void frameShown();
    // A button was pressed on the editor: its pane takes the focus.
    void pressed();

  protected:
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void updatePolish() override;
    void keyPressEvent(QKeyEvent* event) override;
    void keyReleaseEvent(QKeyEvent* event) override;
    void inputMethodEvent(QInputMethodEvent* event) override;
    void focusInEvent(QFocusEvent* event) override;
    void focusOutEvent(QFocusEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseMoveEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;
    void wheelEvent(QWheelEvent* event) override;
    void hoverMoveEvent(QHoverEvent* event) override;

  private:
    // A cell of a grid under a point of this item.
    struct Hit {
      std::uint32_t grid = 0;
      std::uint16_t row = 0;
      std::uint16_t column = 0;
    };

    void refresh(qulonglong pane_id);
    void measure();
    void refreshFonts();
    void resizeEditor();
    void synchronizeGrids(const application::nvim::Editor& editor);
    void synchronizeSeparators(const application::nvim::Editor& editor);
    // The pointer a place of the editor shows: text to select, a separator to drag, or neither.
    [[nodiscard]] Qt::CursorShape pointerAt(QPointF position) const;
    void synchronizeCursor(const application::nvim::Editor& editor);
    void synchronizeSurfaces(const application::nvim::Editor& editor);
    void projectCmdline(const application::nvim::Editor& editor);
    void projectMenu(const application::nvim::Editor& editor);
    void projectMessages(const application::nvim::Editor& editor);
    void projectTabs(const application::nvim::Editor& editor);
    void projectPrompt(const application::nvim::Editor& editor);
    void restartBlink(const application::nvim::Editor& editor);
    [[nodiscard]] QRectF gridBounds(const application::nvim::Grid& grid) const noexcept;
    [[nodiscard]] ds::Option<Hit> hit(QPointF position) const;
    void point(const QMouseEvent& event, application::nvim::NvimMouseAction action);

    QPointer<NvimController> controller_;
    std::uint64_t pane_id_ = 0;
    ListModel grids_;
    QVariantList separators_;
    TerminalFont font_;
    FontGrid font_grid_;
    std::shared_ptr<const FontCollection> font_collection_;
    std::shared_ptr<ResidentFonts> fonts_;
    QPointer<WindowFontCatalog> font_catalog_;
    QMetaObject::Connection font_catalog_connection_;
    qreal font_scale_ = 1;
    std::uint64_t appearance_ = 1;
    QTimer blink_;
    bool cursor_on_ = true;
    QRectF cursor_rect_;
    QString mode_;
    bool ready_ = false;
    QVariantMap cmdline_;
    QVariantMap popup_menu_;
    QVariantMap messages_;
    QVariantMap tabline_;
    QVariantMap prompt_;
    // The revisions of the editor each projection was last made at.
    std::uint64_t layout_revision_ = 0;
    std::uint64_t cmdline_revision_ = 0;
    std::uint64_t menu_revision_ = 0;
    std::uint64_t messages_revision_ = 0;
    std::uint64_t tabs_revision_ = 0;
    std::uint64_t prompt_revision_ = 0;
    application::nvim::EditorCursor blink_cursor_;
    // The button a drag holds, and the wheel's travel not yet a whole row.
    ds::Option<application::nvim::NvimMouseButton> held_;
    ds::Option<Hit> held_at_;
    qreal wheel_rows_ = 0;
    qreal wheel_columns_ = 0;
  };

}
