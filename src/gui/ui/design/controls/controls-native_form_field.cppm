export module telar.gui.ui.design.controls:native_form_field;

import std;
import telar.gui.qt;
import telar.tbc;
import :form_composition_events;
import :form_input_context;
import telar.gui.foundation.forms;
import telar.gui.foundation.text;
import telar.gui.foundation.terminal;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] NativeFormField : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    static constexpr std::size_t text_capacity = 512;
    static constexpr std::size_t composition_capacity = 4096;
    static constexpr std::size_t display_capacity = 8192;

    explicit NativeFormField(QQuickItem* parent = nullptr);
    [[nodiscard]] QString text() const;
    void setText(const QString& text);
    [[nodiscard]] QVariantMap typography() const;
    void setTypography(const QVariantMap& typography);
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

    [[qt::invokable]] void select(int start, int end);
    [[qt::invokable]] void selectAll();
    [[qt::invokable]] void deselect();
    [[qt::invokable]] void copy() const;
    [[qt::invokable]] void cut();
    [[qt::invokable]] void paste();
    [[qt::invokable]] bool cancelComposition();

    [[qt::signal]] void textChanged();
    [[qt::signal]] void textEdited();
    [[qt::signal]] void typographyChanged();
    [[qt::signal]] void ratioChanged();
    [[qt::signal]] void formControlChanged();
    [[qt::signal]] void maximumBytesChanged();
    [[qt::signal]] void selectionChanged();
    [[qt::signal]] void layoutChanged();
    [[qt::signal]] void accepted();
    [[qt::signal]] void limitReached(qulonglong requested_bytes);

  protected:
    void updatePolish() override;
    void componentComplete() override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    void keyPressEvent(QKeyEvent* event) override;
    void inputMethodEvent(QInputMethodEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseMoveEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;
    void mouseDoubleClickEvent(QMouseEvent* event) override;
    void mouseUngrabEvent() override;
    void focusOutEvent(QFocusEvent* event) override;

  private:
    using Editor = BoundedEditor<text_capacity>;

    [[nodiscard]] static int utf16Position(std::string_view text, std::size_t offset);
    [[nodiscard]] static std::size_t bytePosition(const QString& text, int offset);
    [[nodiscard]] std::size_t pointerPosition(qreal x) const;
    void resolveGrid();
    void publish(bool edited);
    void updateInputContext();
    void invalidateLayout();
    void insertText(const QString& text);
    void clearComposition();
    [[nodiscard]] bool editKey(const QKeyEvent& event);
    void commitInput(const QInputMethodEvent& event);
    void updateComposition(const QInputMethodEvent& event);

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
    [[no_unique_address]] tbc::val_self<ActiveCompositionEvents> composition_events_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("text", &NativeFormField::text).withWrite(&NativeFormField::setText).withNotify(&NativeFormField::textChanged),
        telar::qt::property("typography", &NativeFormField::typography).withWrite(&NativeFormField::setTypography).withNotify(&NativeFormField::typographyChanged),
        telar::qt::property("ratio", &NativeFormField::ratio).withWrite(&NativeFormField::setRatio).withNotify(&NativeFormField::ratioChanged),
        telar::qt::property("formControl", &NativeFormField::formControl).withWrite(&NativeFormField::setFormControl).withNotify(&NativeFormField::formControlChanged),
        telar::qt::property("maximumBytes", &NativeFormField::maximumBytes).withWrite(&NativeFormField::setMaximumBytes).withNotify(&NativeFormField::maximumBytesChanged),
        telar::qt::property("cursorPosition", &NativeFormField::cursorPosition).withWrite(&NativeFormField::setCursorPosition).withNotify(&NativeFormField::selectionChanged),
        telar::qt::property("selectionStart", &NativeFormField::selectionStart).withNotify(&NativeFormField::selectionChanged),
        telar::qt::property("selectionEnd", &NativeFormField::selectionEnd).withNotify(&NativeFormField::selectionChanged),
        telar::qt::property("selectedText", &NativeFormField::selectedText).withNotify(&NativeFormField::selectionChanged),
        telar::qt::property("layout", &NativeFormField::layout).withNotify(&NativeFormField::layoutChanged)
    );
  };

}
