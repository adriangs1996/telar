export module telar.gui.ui.design.controls:native_chrome_text;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.scene;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.gui.foundation.terminal;
import telar.gui.foundation.text;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] NativeChromeText : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit NativeChromeText(QQuickItem* parent = nullptr);
    [[nodiscard]] QString text() const;
    void setText(const QString& text);
    [[nodiscard]] qreal pixelSize() const noexcept;
    void setPixelSize(qreal size);
    [[nodiscard]] QColor color() const;
    void setColor(const QColor& color);
    [[nodiscard]] qreal fadeWidth() const noexcept;
    void setFadeWidth(qreal width);
    [[nodiscard]] bool emphasized() const noexcept;
    void setEmphasized(bool emphasized);
    [[nodiscard]] bool caption() const noexcept;
    void setCaption(bool caption);
    [[nodiscard]] int elide() const noexcept;
    void setElide(int elide);
    [[nodiscard]] int horizontalAlignment() const noexcept;
    void setHorizontalAlignment(int alignment);
    [[nodiscard]] bool wholePixelCentering() const noexcept;
    void setWholePixelCentering(bool enabled);
    [[nodiscard]] bool supported() const noexcept;
    [[nodiscard]] bool available() const noexcept;

    [[qt::signal]] void textChanged();
    [[qt::signal]] void pixelSizeChanged();
    [[qt::signal]] void colorChanged();
    [[qt::signal]] void emphasizedChanged();
    [[qt::signal]] void layoutChanged();
    [[qt::signal]] void availabilityChanged();
    [[qt::signal]] void supportChanged();

  protected:
    void updatePolish() override;
    void componentComplete() override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;

  private:
    void invalidateLayout();
    void refreshLayout();
    void refreshFit();
    void refreshAvailability();
    void setSupported(bool supported);
    void refreshFonts();

    // The text fitted to the item's width, shaped apart from the full text it is cut from.
    struct FittedText {
      [[tbc::hot_path]] inline explicit FittedText(ConcurrentMemory& memory)
          : glyphs(memory) {}

      void shape(ResidentFonts& fonts, std::string_view fitted, fonts::TextRequest request);

      fonts::TextLayout<ConcurrentMemory> glyphs;
      TextFit::Buffer text{};
      std::size_t bytes = 0;
      std::int32_t advance = 0;
      bool dirty = true;
    };

    SystemAllocator memory_;
    MemoryAdapter<SystemAllocator> adapter_{memory_};
    fonts::TextLayout<ConcurrentMemory> glyphs_;
    FittedText fit_;
    // The ancestors are watched through this item, which stays where Qt made it.
    tbc::val_self<AncestorGeometry> ancestors_;
    std::shared_ptr<ResidentFonts> fonts_;
    std::shared_ptr<const FontCollection> collection_;
    QPointer<WindowFontCatalog> catalog_;
    QMetaObject::Connection catalog_connection_;
    QString text_;
    QByteArray utf8_;
    QColor color_;
    FontMetrics metrics_;
    qreal pixel_size_ = ChromeMetrics{}.body;
    qreal display_scale_ = 1;
    qreal fade_width_ = 0;
    std::uint64_t revision_ = 0;
    std::int32_t advance_ = 0;
    std::uint16_t pixel_height_ = 0;
    Qt::TextElideMode elide_ = Qt::ElideRight;
    Qt::Alignment alignment_ = Qt::AlignLeft;
    bool whole_pixel_centering_ = false;
    bool emphasized_ = false;
    bool caption_ = false;
    bool supported_ = false;
    bool available_ = false;
    bool layout_dirty_ = true;
    bool fit_dirty_ = true;
    bool fitted_ = false;
    bool render_failed_ = false;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("text", &NativeChromeText::text).withWrite(&NativeChromeText::setText).withNotify(&NativeChromeText::textChanged),
        telar::qt::property("pixelSize", &NativeChromeText::pixelSize).withWrite(&NativeChromeText::setPixelSize).withNotify(&NativeChromeText::pixelSizeChanged),
        telar::qt::property("color", &NativeChromeText::color).withWrite(&NativeChromeText::setColor).withNotify(&NativeChromeText::colorChanged),
        telar::qt::property("fadeWidth", &NativeChromeText::fadeWidth).withWrite(&NativeChromeText::setFadeWidth).withNotify(&NativeChromeText::layoutChanged),
        telar::qt::property("emphasized", &NativeChromeText::emphasized).withWrite(&NativeChromeText::setEmphasized).withNotify(&NativeChromeText::emphasizedChanged),
        telar::qt::property("caption", &NativeChromeText::caption).withWrite(&NativeChromeText::setCaption).withNotify(&NativeChromeText::layoutChanged),
        telar::qt::property("elide", &NativeChromeText::elide).withWrite(&NativeChromeText::setElide).withNotify(&NativeChromeText::layoutChanged),
        telar::qt::property("horizontalAlignment", &NativeChromeText::horizontalAlignment).withWrite(&NativeChromeText::setHorizontalAlignment).withNotify(&NativeChromeText::layoutChanged),
        telar::qt::property("wholePixelCentering", &NativeChromeText::wholePixelCentering).withWrite(&NativeChromeText::setWholePixelCentering).withNotify(&NativeChromeText::layoutChanged),
        telar::qt::property("supported", &NativeChromeText::supported).withNotify(&NativeChromeText::supportChanged),
        telar::qt::property("available", &NativeChromeText::available).withNotify(&NativeChromeText::availabilityChanged)
    );
  };

}
