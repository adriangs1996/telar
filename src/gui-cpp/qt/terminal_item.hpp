#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "application.hpp"
#include "font_collection.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <optional>
#include <array>
#include <charconv>
#include <limits>
#include <string_view>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <tuple>
#include "../input/wheel_accumulator.hpp"
#include "link_presentation.hpp"
#include "link_preview.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "../terminal/cell_position.hpp"
#include <utility>
#include "resident_fonts.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <chrono>
#include "terminal_preparation.hpp"
#include "terminal_font.hpp"
#include "window_font_catalog.hpp"
#include <QKeyEvent>
#include <QList>
#include <QPointer>
#include <QQuickItem>
#include <QElapsedTimer>
#include <QTimer>
#include <QtQml/qqmlregistration.h>
#include <memory>

#pragma once

#include "input/wheel_accumulator.hpp"


import telar.gui.core.metrics;
import telar.gui.input.child_mouse;
import telar.gui.input.configuration;
import telar.gui.input.key_encoder;
import telar.gui.links.link_hover;
import telar.gui.links.path_expansion;
import telar.gui.terminal.font_grid;

namespace telar::gui::test {
class TerminalCursor;
}

namespace telar::gui::qt {

class TerminalItem : public QQuickItem {
  Q_OBJECT
  QML_NAMED_ELEMENT(TerminalView)
  Q_PROPERTY(QObject *application READ application WRITE setApplication NOTIFY applicationChanged)
  Q_PROPERTY(QString paneId READ paneId WRITE setPaneId NOTIFY paneIdChanged)
  Q_PROPERTY(bool backgroundProvided READ backgroundProvided WRITE setBackgroundProvided NOTIFY backgroundProvidedChanged)
  Q_PROPERTY(QString hoveredLink READ hoveredLink NOTIFY linkHoverChanged)
  Q_PROPERTY(QVariantMap linkPreview READ linkPreview NOTIFY linkHoverChanged)
  // The text an input method is composing; telar's command editor shows it at its caret.
  Q_PROPERTY(QString preeditText READ preeditText NOTIFY preeditChanged)
  // Where telar's command editor draws its caret, in this item's coordinates, for the input method.
  Q_PROPERTY(QRectF promptCaret READ promptCaret WRITE setPromptCaret NOTIFY promptCaretChanged)
  // The commands the shell ran whose prompts are on screen, each drawn as a separator over
  // its last row; every command, for the rail beside the pane; and the row the command at
  // the editor's prompt will have its separator on, or -1. Only while telar's editor stands
  // in for the shell's.
  Q_PROPERTY(QVariantList separators READ separators NOTIFY blocksChanged)
  Q_PROPERTY(QVariantList rail READ rail NOTIFY blocksChanged)
  Q_PROPERTY(int promptRow READ promptRow NOTIFY blocksChanged)
  Q_PROPERTY(QSizeF cell READ cellSize NOTIFY blocksChanged)
  // Where telar's prompt line stands: the first row of the shell's hidden prompt, or -1; the
  // live cursor's row, where a running program prints, or -1 when it is out of view; the
  // screen's rows; and the rows of scrollback below the view. They change with every line a
  // program prints, so they notify apart from the blocks, which rebuild the separators.
  Q_PROPERTY(int promptTop READ promptTop NOTIFY placeChanged)
  Q_PROPERTY(int cursorRow READ cursorRow NOTIFY placeChanged)
  Q_PROPERTY(int rows READ rows NOTIFY placeChanged)
  Q_PROPERTY(int rowsBelow READ rowsBelow NOTIFY placeChanged)

public:
  explicit TerminalItem(QQuickItem *parent = nullptr);
  ~TerminalItem() override;
  TerminalItem(const TerminalItem &) = delete;
  TerminalItem &operator=(const TerminalItem &) = delete;
  TerminalItem(TerminalItem &&) = delete;
  TerminalItem &operator=(TerminalItem &&) = delete;

  [[nodiscard]] QObject *application() const noexcept;
  void setApplication(QObject *application);
  [[nodiscard]] QString paneId() const;
  [[nodiscard]] std::uint64_t paneIdentity() const noexcept;
  void setPaneId(const QString &identity);
  [[nodiscard]] QSizeF cellSize() const noexcept;
  [[nodiscard]] bool backgroundProvided() const noexcept;
  void setBackgroundProvided(bool provided);
  [[nodiscard]] QVariant inputMethodQuery(Qt::InputMethodQuery query) const override;
  [[nodiscard]] QString hoveredLink() const;
  [[nodiscard]] QVariantMap linkPreview() const;
  Q_INVOKABLE void setLinkPreviewBounds(const QRectF &bounds);
  [[nodiscard]] QString preeditText() const;
  [[nodiscard]] QRectF promptCaret() const noexcept;
  void setPromptCaret(const QRectF &caret);
  [[nodiscard]] QVariantList separators() const;
  [[nodiscard]] QVariantList rail() const;
  [[nodiscard]] int promptRow() const noexcept;
  [[nodiscard]] int promptTop() const noexcept {
    return prompt_top_;
  }
  [[nodiscard]] int cursorRow() const noexcept {
    return cursor_row_;
  }
  [[nodiscard]] int rows() const noexcept {
    return rows_;
  }
  [[nodiscard]] int rowsBelow() const noexcept {
    return rows_below_;
  }
  // Selects the command at `index` among the rail's, oldest first, and shows it.
  Q_INVOKABLE void selectBlock(int index);
  // While the line the editor sent turns into its separator, the rows from its prompt down
  // stay unpainted; released, the first screen of its output enters line by line. The
  // command runs all along: only what is shown waits, and never longer than a moment.
  Q_INVOKABLE void holdOutput();
  Q_INVOKABLE void releaseOutput();
  [[nodiscard]] bool outputHeld() const noexcept {
    return held_from_.has_value();
  }
  [[nodiscard]] std::optional<PresentedLink> prepareLinkPresentation() const;

signals:
  void applicationChanged();
  void paneIdChanged();
  void backgroundProvidedChanged();
  void linkHoverChanged();
  void preeditChanged();
  void promptCaretChanged();
  void blocksChanged();
  void placeChanged();

protected:
  void updatePolish() override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;
  QSGNode *updatePaintNode(QSGNode *previous, UpdatePaintNodeData *update_data) override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void keyPressEvent(QKeyEvent *event) override;
  void keyReleaseEvent(QKeyEvent *event) override;
  void inputMethodEvent(QInputMethodEvent *event) override;
  void focusInEvent(QFocusEvent *event) override;
  void focusOutEvent(QFocusEvent *event) override;
  void mousePressEvent(QMouseEvent *event) override;
  void mouseDoubleClickEvent(QMouseEvent *event) override;
  void mouseMoveEvent(QMouseEvent *event) override;
  void mouseReleaseEvent(QMouseEvent *event) override;
  void mouseUngrabEvent() override;
  void wheelEvent(QWheelEvent *event) override;
  void hoverMoveEvent(QHoverEvent *event) override;
  void hoverEnterEvent(QHoverEvent *event) override;
  void hoverLeaveEvent(QHoverEvent *event) override;

private:
  friend class Application;
  friend class PointerDispatcher;
  friend class test::TerminalCursor;

  static constexpr std::size_t physical_key_capacity = 128;
  static constexpr unsigned mouse_shift = 4;
  static constexpr unsigned mouse_alt = 8;
  static constexpr unsigned mouse_control = 16;

  void measure();
  void refreshFonts();
  void requestRowFonts(std::span<const CellValue> cells);
  void refresh();
  void refreshBlocks();
  void presentFrame(const TerminalPreparation &preparation);
  void resizeTerminal();
  void synchronizeFocus();
  void releaseKeys();
  void invalidateMachine();
  void releaseMouse();
  bool send(const QByteArray &bytes, PaneInputSource source = PaneInputSource::keyboard);
  [[nodiscard]] ChildMouseView childMouseView() const;
  [[nodiscard]] ChildMouseSample childMouseSample(const QMouseEvent &event, MousePhase phase, MouseButton button) const;
  void mousePacket(unsigned button, QPointF position, bool released);
  bool sendKeyPress(const QKeyEvent &event, const InputModes &modes);
  void sendCommittedText(const QString &text);
  void dispatchWheel(const QWheelEvent &event, std::int32_t lines);
  [[nodiscard]] int indexAt(QPointF position) const noexcept;
  [[nodiscard]] CopyPointerInput pointerInput(QPointF position, CopyPointerKind kind, bool left_button = true, std::int32_t rows = 0) const noexcept;
  [[nodiscard]] static unsigned mouseModifiers(Qt::KeyboardModifiers modifiers) noexcept;
  [[nodiscard]] Pane<ApplicationAllocator> *pane() const noexcept;
  void observeLinkPointer(QPointF position, Qt::KeyboardModifiers modifiers);
  void refreshLinkHover();
  void clearLinkHover();
  bool beginLinkPress(const QMouseEvent &event);
  void finishLinkRelease(const QMouseEvent &event);
  [[nodiscard]] TerminalSurface terminalSurface() const;
  [[nodiscard]] bool linkEligible() const noexcept;
  [[nodiscard]] static LinkModifiers linkModifiers(Qt::KeyboardModifiers modifiers) noexcept;

  struct ResolvedLink {
    LinkAffordance affordance = LinkAffordance::text;
    std::optional<LinkHit> hit;
  };

  [[nodiscard]] ResolvedLink resolveLink(QPointF position, LinkModifiers modifiers) const;
  [[nodiscard]] std::optional<CellPosition> visibleCellAt(QPointF position) const noexcept;

  struct LinkStamp {
    CellPosition cell;
    ViewVersion version;
    TerminalSurface surface;
    std::uint64_t screen_revision;
    Qt::KeyboardModifiers modifiers;
    std::uint64_t presentation_revision;
    bool frame_presented;

    bool operator==(const LinkStamp &) const = default;
  };

  Application *application_ = nullptr;
  std::uint64_t pane_id_ = 0;
  std::vector<std::uint8_t> hidden_rows_;
  QVariantList separators_;
  QVariantList rail_;
  int prompt_row_ = -1;
  int prompt_top_ = -1;
  int cursor_row_ = -1;
  int rows_ = 0;
  int rows_below_ = 0;
  QSizeF shown_cell_;
  // Output held from this row on, counted from the top of the scrollback, and then revealed
  // from it: `reveal_rows_` rows, one every `reveal_step_ms_`.
  std::optional<std::uint64_t> held_from_;
  std::uint64_t reveal_from_ = 0;
  std::uint64_t reveal_rows_ = 0;
  qint64 reveal_step_ms_ = 0;
  QElapsedTimer reveal_clock_;
  std::vector<float> revealed_rows_;
  QTimer hold_limit_;
  TerminalFont font_;
  FontGrid font_grid_;
  std::shared_ptr<const FontCollection> font_collection_;
  std::shared_ptr<ResidentFonts> fonts_;
  QPointer<WindowFontCatalog> font_catalog_;
  QMetaObject::Connection font_catalog_connection_;
  QList<std::uint64_t> font_row_revisions_;
  qreal font_scale_ = 1;
  QTimer blink_;
  QMetaObject::Connection window_activity_connection_;
  std::uint64_t appearance_ = 1;
  bool cursor_on_ = true;
  bool selecting_ = false;
  bool keyboard_ = false;
  bool background_provided_ = false;
  bool window_active_ = false;

  struct PressedKey {
    int key = 0;
    Qt::KeyboardModifiers modifiers;
    quint32 scan = 0;
    quint32 native_key = 0;
    quint32 native_modifiers = 0;
    QString text;
    std::optional<TerminalKey> semantic = std::nullopt;

    [[nodiscard]] QByteArray release(const InputModes &modes) const;

    [[nodiscard]] bool matches(const QKeyEvent &event) const noexcept {
      return key != 0 && (event.nativeScanCode() != 0 ? scan == event.nativeScanCode() : key == event.key());
    }
  };

  std::array<PressedKey, physical_key_capacity> pressed_keys_;
  WheelAccumulator wheel_;
  QPointF selection_position_;
  QString preedit_;
  QRectF prompt_caret_;
  LinkHover link_hover_;
  std::shared_ptr<const LinkHit> shared_link_;
  LinkGesture link_gesture_;
  std::optional<QPointF> link_pointer_;
  std::optional<LinkStamp> link_stamp_;
  std::optional<LinkPreview> link_preview_;
  std::optional<Rect> preview_cover_;
  Qt::MouseButtons captured_link_buttons_;
  std::uint64_t presented_frame_id_ = 0;
  std::uint64_t presented_revision_ = 0;
  TerminalPreparation prepared_frame_;
  std::uint64_t link_presentation_revision_ = 0;
};

}
