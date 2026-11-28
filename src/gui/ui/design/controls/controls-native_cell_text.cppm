export module telar.gui.ui.design.controls:native_cell_text;

import std;
import telar.gui.qt;
import telar.tbc;
import :cell_text_grid;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.scene;
import telar.base.memory.allocators;
import telar.gui.foundation.fonts;
import telar.gui.foundation.core;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] NativeCellText : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit NativeCellText(QQuickItem* parent = nullptr);
    [[nodiscard]] QString text() const;
    void setText(const QString& text);
    [[nodiscard]] QVariantMap grid() const;
    void setGrid(const QVariantMap& grid);
    [[nodiscard]] QColor color() const;
    void setColor(const QColor& color);
    [[nodiscard]] bool bold() const noexcept;
    void setBold(bool bold);
    [[nodiscard]] bool available() const noexcept;

    [[qt::signal]] void textChanged();
    [[qt::signal]] void gridChanged();
    [[qt::signal]] void colorChanged();
    [[qt::signal]] void boldChanged();
    [[qt::signal]] void availabilityChanged();

  protected:
    void updatePolish() override;
    void componentComplete() override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;

  private:
    static constexpr std::size_t maximum_text_bytes = 8192;
    void invalidateLayout();
    void refreshLayout();
    void refreshFonts();
    void setAvailable(bool available);

    SystemAllocator memory_;
    MemoryAdapter<SystemAllocator> adapter_{memory_};
    fonts::CellTextLayout<ConcurrentMemory> layout_;
    tbc::val_self<AncestorGeometry> ancestors_;
    std::shared_ptr<const FontCollection> collection_;
    std::shared_ptr<ResidentFonts> fonts_;
    QPointer<WindowFontCatalog> catalog_;
    QMetaObject::Connection catalog_connection_;
    CellTextGrid resolved_;
    QVariantMap grid_;
    QString text_;
    QColor color_;
    qreal scale_ = 1;
    std::uint64_t revision_ = 0;
    bool bold_ = false;
    bool available_ = false;
    bool layout_dirty_ = true;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("text", &NativeCellText::text).withWrite(&NativeCellText::setText).withNotify(&NativeCellText::textChanged),
        telar::qt::property("grid", &NativeCellText::grid).withWrite(&NativeCellText::setGrid).withNotify(&NativeCellText::gridChanged),
        telar::qt::property("color", &NativeCellText::color).withWrite(&NativeCellText::setColor).withNotify(&NativeCellText::colorChanged),
        telar::qt::property("bold", &NativeCellText::bold).withWrite(&NativeCellText::setBold).withNotify(&NativeCellText::boldChanged),
        telar::qt::property("available", &NativeCellText::available).withNotify(&NativeCellText::availabilityChanged)
    );
  };

}
