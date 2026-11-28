export module telar.gui.ui.design.controls:provider_mark;

import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.scene;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] ProviderMark : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit ProviderMark(QQuickItem* parent = nullptr);
    ~ProviderMark() override;
    ProviderMark(const ProviderMark&) = delete;
    ProviderMark& operator=(const ProviderMark&) = delete;
    ProviderMark(ProviderMark&&) = delete;
    ProviderMark& operator=(ProviderMark&&) = delete;
    [[nodiscard]] static qreal dimmedAlpha() noexcept;
    [[nodiscard]] int provider() const noexcept;
    void setProvider(int provider);
    [[nodiscard]] bool telarMark() const noexcept;
    void setTelarMark(bool enabled);
    // A bundled line icon by name, tinted with `color`; it takes the place of the provider's mark.
    [[nodiscard]] QString symbol() const;
    void setSymbol(const QString& symbol);
    [[nodiscard]] bool monochrome() const noexcept;
    void setMonochrome(bool monochrome);
    [[nodiscard]] int theme() const noexcept;
    void setTheme(int theme);
    [[nodiscard]] QColor color() const;
    void setColor(const QColor& color);
    [[nodiscard]] qreal ratio() const noexcept;
    void setRatio(qreal ratio);

    [[qt::signal]] void providerChanged();
    [[qt::signal]] void telarMarkChanged();
    [[qt::signal]] void symbolChanged();
    [[qt::signal]] void monochromeChanged();
    [[qt::signal]] void themeChanged();
    [[qt::signal]] void colorChanged();
    [[qt::signal]] void ratioChanged();

  protected:
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    tbc::val_self<AncestorGeometry> ancestors_;
    AgentProvider provider_ = AgentProvider::unknown;
    bool telar_mark_ = false;
    QString symbol_;
    bool monochrome_ = false;
    int theme_ = -1;
    QColor color_;
    qreal ratio_ = 1;
    bool dirty_ = true;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("dimmedAlpha", &ProviderMark::dimmedAlpha).constant(),
        telar::qt::property("provider", &ProviderMark::provider).withWrite(&ProviderMark::setProvider).withNotify(&ProviderMark::providerChanged),
        telar::qt::property("telarMark", &ProviderMark::telarMark).withWrite(&ProviderMark::setTelarMark).withNotify(&ProviderMark::telarMarkChanged),
        telar::qt::property("symbol", &ProviderMark::symbol).withWrite(&ProviderMark::setSymbol).withNotify(&ProviderMark::symbolChanged),
        telar::qt::property("monochrome", &ProviderMark::monochrome).withWrite(&ProviderMark::setMonochrome).withNotify(&ProviderMark::monochromeChanged),
        telar::qt::property("theme", &ProviderMark::theme).withWrite(&ProviderMark::setTheme).withNotify(&ProviderMark::themeChanged),
        telar::qt::property("color", &ProviderMark::color).withWrite(&ProviderMark::setColor).withNotify(&ProviderMark::colorChanged),
        telar::qt::property("ratio", &ProviderMark::ratio).withWrite(&ProviderMark::setRatio).withNotify(&ProviderMark::ratioChanged)
    );
  };

}
