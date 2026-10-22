#pragma once

#include "terminal_screen.hpp"
#include <QQuickItem>
#include <QTimer>
#include <QFont>
#include <QSet>
#include <functional>
#include <memory>

namespace workbench {
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
    QFont font_;
    bool fixed_pitch_ = true;
    QColor foreground_{"#cdd6f4"}, background_{"#1b1723"}, selection_{"#45475a"};
    QSizeF cell_{8, 16};
    double ascent_ = 12;
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
    void resizeTerminal();
    void syncKeyboard();
    void watchConnection();
    int indexAt(QPointF point) const;
    void reportMouse(QMouseEvent *event, bool release, bool motion);
    void mousePacket(int button, QPointF point, bool release);
    QString selectionText() const;
  };
} // namespace workbench
