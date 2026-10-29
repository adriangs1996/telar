#pragma once

#include "form_composition_events.hpp"
#include "form_input_context.hpp"
#include "presentation/form_field_geometry.hpp"
#include "text/bounded_editor.hpp"
#include <QByteArray>
#include <QFocusEvent>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QQuickItem>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <cstddef>

namespace telar::gui::qt {

class NativeFormField : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QString text READ text WRITE setText NOTIFY textChanged)
  Q_PROPERTY(QVariantMap typography READ typography WRITE setTypography NOTIFY typographyChanged)
  Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY ratioChanged)
  Q_PROPERTY(bool formControl READ formControl WRITE setFormControl NOTIFY formControlChanged)
  Q_PROPERTY(int maximumBytes READ maximumBytes WRITE setMaximumBytes NOTIFY maximumBytesChanged)
  Q_PROPERTY(int cursorPosition READ cursorPosition WRITE setCursorPosition NOTIFY selectionChanged)
  Q_PROPERTY(int selectionStart READ selectionStart NOTIFY selectionChanged)
  Q_PROPERTY(int selectionEnd READ selectionEnd NOTIFY selectionChanged)
  Q_PROPERTY(QString selectedText READ selectedText NOTIFY selectionChanged)
  Q_PROPERTY(QVariantMap layout READ layout NOTIFY layoutChanged)

public:
  static constexpr std::size_t text_capacity = 512;
  static constexpr std::size_t composition_capacity = 4096;
  static constexpr std::size_t display_capacity = 8192;

  explicit NativeFormField(QQuickItem *parent = nullptr);
  [[nodiscard]] QString text() const;
  void setText(const QString &text);
  [[nodiscard]] QVariantMap typography() const;
  void setTypography(const QVariantMap &typography);
  [[nodiscard]] qreal ratio() const noexcept;
  void setRatio(qreal ratio);
  [[nodiscard]] bool formControl() const noexcept;
  void setFormControl(bool enabled);
  [[nodiscard]] int maximumBytes() const noexcept;
  void setMaximumBytes(int capacity);
  [[nodiscard]] int cursorPosition() const;
  void setCursorPosition(int position);
  [[nodiscard]] int selectionStart() const;
  [[nodiscard]] int selectionEnd() const;
  [[nodiscard]] QString selectedText() const;
  [[nodiscard]] QVariantMap layout() const;
  [[nodiscard]] QVariant inputMethodQuery(Qt::InputMethodQuery query) const override;

  Q_INVOKABLE void select(int start, int end);
  Q_INVOKABLE void selectAll();
  Q_INVOKABLE void deselect();
  Q_INVOKABLE void copy() const;
  Q_INVOKABLE void cut();
  Q_INVOKABLE void paste();
  Q_INVOKABLE bool cancelComposition();

signals:
  void textChanged();
  void textEdited();
  void typographyChanged();
  void ratioChanged();
  void formControlChanged();
  void maximumBytesChanged();
  void selectionChanged();
  void layoutChanged();
  void accepted();
  void limitReached(qulonglong requested_bytes);

protected:
  void updatePolish() override;
  void componentComplete() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;
  void keyPressEvent(QKeyEvent *event) override;
  void inputMethodEvent(QInputMethodEvent *event) override;
  void mousePressEvent(QMouseEvent *event) override;
  void mouseMoveEvent(QMouseEvent *event) override;
  void mouseReleaseEvent(QMouseEvent *event) override;
  void mouseDoubleClickEvent(QMouseEvent *event) override;
  void mouseUngrabEvent() override;
  void focusOutEvent(QFocusEvent *event) override;

private:
  using Editor = BoundedEditor<text_capacity>;

  [[nodiscard]] static int utf16Position(std::string_view text, std::size_t offset);
  [[nodiscard]] static std::size_t bytePosition(const QString &text, int offset);
  [[nodiscard]] std::size_t pointerPosition(qreal x) const;
  void resolveGrid();
  void publish(bool edited);
  void updateInputContext();
  void invalidateLayout();
  void insertText(const QString &text);
  void clearComposition();
  [[nodiscard]] bool editKey(const QKeyEvent &event);
  void commitInput(const QInputMethodEvent &event);
  void updateComposition(const QInputMethodEvent &event);

  Editor editor_;
  QString text_;
  FormInputContext input_context_;
  QVariantMap typography_;
  QVariantMap layout_;
  QVariantMap grid_;
  FontGrid font_grid_;
  QByteArray composition_;
  std::size_t composition_first_ = 0;
  std::size_t composition_last_ = 0;
  std::size_t composition_anchor_ = 0;
  std::size_t composition_head_ = 0;
  std::size_t pressed_anchor_ = 0;
  qreal ratio_ = 1;
  qreal density_ = 1;
  int maximum_bytes_ = text_capacity;
  FormFieldGeometry geometry_;
  bool dragging_ = false;
  bool discarding_composition_ = false;
  bool metrics_dirty_ = true;
  bool form_control_ = true;
  [[no_unique_address]] ActiveCompositionEvents composition_events_;
};

}
