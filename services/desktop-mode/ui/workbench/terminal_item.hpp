#pragma once

#include "terminal_screen.hpp"
#include <QColor>
#include <QQuickItem>
#include <QTimer>
#include <QFont>
#include <QSet>
#include <array>
#include <functional>
#include <memory>

namespace workbench {
  // The first 16 indexed colors.
  using TerminalPalette = std::array<QColor, 16>;

  class TerminalItem final : public QQuickItem {
  public:
    explicit TerminalItem(std::shared_ptr<TerminalScreen> screen, QQuickItem *parent);
    std::function<void(const QByteArray &)> send;
    std::function<void(telar::TerminalSize)> resized;
    std::function<void(std::uint32_t)> scrolled;
    void configure(const QVariantMap &options);
    void refresh();
    void setPresented(bool presented);
    QVariant inputMethodQuery(Qt::InputMethodQuery query) const override;
    QSizeF cellSize() const;

  protected:
    QSGNode *updatePaintNode(QSGNode *previous, UpdatePaintNodeData *) override;
    void geometryChange(const QRectF &current, const QRectF &previous) override;
    void keyPressEvent(QKeyEvent *event) override;
    void keyReleaseEvent(QKeyEvent *event) override;
    void inputMethodEvent(QInputMethodEvent *event) override;
    void focusInEvent(QFocusEvent *event) override;
    void focusOutEvent(QFocusEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void mouseUngrabEvent() override;
    void wheelEvent(QWheelEvent *event) override;

  private:
    std::shared_ptr<TerminalScreen> screen_;
    // The theme's `terminal.font`; measured again when the display scale changes.
    QVariantMap font_settings_;
    // Regular, bold, italic and bold italic, each spaced so its advance is one cell.
    std::array<QFont, 4> faces_;
    bool fixed_pitch_ = true;
    bool thicken_ = false;
    std::uint8_t thicken_strength_ = 255;
    qreal background_opacity_ = 1;
    // The theme sets these on configure; until then cells paint with Qt's defaults.
    QColor foreground_, background_, selection_, cursor_color_;
    TerminalPalette palette_{};
    QSizeF cell_{8, 16};
    // From the top of a cell, in logical pixels on the physical pixel grid.
    double baseline_ = 12;
    std::uint64_t appearance_ = 1;
    QTimer blink_, waiting_timer_;
    bool cursor_on_ = true, selecting_ = false, mouse_report_ = false, waiting_ = false,
         presented_ = false, keyboard_ = false;
    int anchor_ = -1, end_ = -1;
    QString preedit_;
    QSet<int> pressed_keys_;
    int wheel_remainder_ = 0;
    int captured_button_ = 0;
    QPointF captured_position_;
    void measure();
    void resizeTerminal();
    void syncKeyboard();
    void watchConnection();
    int indexAt(QPointF point) const;
    void reportMouse(QMouseEvent *event, bool release, bool motion);
    void mousePacket(int button, QPointF point, bool release);
    QString selectionText() const;
  };
} // namespace workbench
