export module telar.gui.ui.design.controls:native_chrome_icon;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.scene;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.gui.foundation.fonts;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] NativeChromeIcon : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit NativeChromeIcon(QQuickItem* parent = nullptr);
    [[nodiscard]] QString glyph() const;
    void setGlyph(const QString& glyph);
    [[nodiscard]] QColor color() const;
    void setColor(const QColor& color);
    [[nodiscard]] qreal pixelSize() const noexcept;
    void setPixelSize(qreal size);
    [[nodiscard]] QString primaryFamily() const;
    void setPrimaryFamily(const QString& family);
    [[nodiscard]] QString primaryStyle() const;
    void setPrimaryStyle(const QString& style);
    [[nodiscard]] bool available() const noexcept;

    [[qt::signal]] void glyphChanged();
    [[qt::signal]] void colorChanged();
    [[qt::signal]] void pixelSizeChanged();
    [[qt::signal]] void fontChanged();
    [[qt::signal]] void availabilityChanged();

  protected:
    void updatePolish() override;
    void componentComplete() override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;

  private:
    void invalidateLayout();
    void refreshLayout();
    void setAvailable(bool available);

    SystemAllocator memory_;
    MemoryAdapter<SystemAllocator> adapter_{memory_};
    fonts::IconLayout<ConcurrentMemory> layout_;
    tbc::val_self<AncestorGeometry> ancestors_;
    std::shared_ptr<const FontAsset> source_;
    std::shared_ptr<ResidentFonts> fonts_;
    QString glyph_;
    QString primary_family_;
    QString primary_style_;
    QColor color_;
    qreal pixel_size_ = ChromeMetrics{}.body;
    qreal display_scale_ = 1;
    float target_side_ = 0;
    std::uint16_t pixel_height_ = 0;
    std::uint64_t revision_ = 0;
    bool available_ = false;
    bool layout_dirty_ = true;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("glyph", &NativeChromeIcon::glyph).withWrite(&NativeChromeIcon::setGlyph).withNotify(&NativeChromeIcon::glyphChanged),
        telar::qt::property("color", &NativeChromeIcon::color).withWrite(&NativeChromeIcon::setColor).withNotify(&NativeChromeIcon::colorChanged),
        telar::qt::property("pixelSize", &NativeChromeIcon::pixelSize).withWrite(&NativeChromeIcon::setPixelSize).withNotify(&NativeChromeIcon::pixelSizeChanged),
        telar::qt::property("primaryFamily", &NativeChromeIcon::primaryFamily).withWrite(&NativeChromeIcon::setPrimaryFamily).withNotify(&NativeChromeIcon::fontChanged),
        telar::qt::property("primaryStyle", &NativeChromeIcon::primaryStyle).withWrite(&NativeChromeIcon::setPrimaryStyle).withNotify(&NativeChromeIcon::fontChanged),
        telar::qt::property("available", &NativeChromeIcon::available).withNotify(&NativeChromeIcon::availabilityChanged)
    );
  };

}
