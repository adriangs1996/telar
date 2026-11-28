export module telar.gui.ui.app.panes:native_pane_attention;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.scene;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] NativePaneAttention : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    class WindowAnimationSet;

    explicit NativePaneAttention(QQuickItem* parent = nullptr);
    ~NativePaneAttention() override;
    NativePaneAttention(const NativePaneAttention&) = delete;
    NativePaneAttention& operator=(const NativePaneAttention&) = delete;
    NativePaneAttention(NativePaneAttention&&) = delete;
    NativePaneAttention& operator=(NativePaneAttention&&) = delete;

    [[nodiscard]] QVariant attachment() const;
    void setAttachment(const QVariant& attachment);
    [[nodiscard]] bool active() const noexcept;
    void setActive(bool active);
    [[nodiscard]] QColor color() const;
    void setColor(const QColor& color);
    [[nodiscard]] qreal ratio() const noexcept;
    void setRatio(qreal ratio);
    [[nodiscard]] qreal radius() const noexcept;
    void setRadius(qreal radius);
    [[nodiscard]] qreal alpha() const noexcept;

    [[qt::signal]] void attachmentChanged();
    [[qt::signal]] void activeChanged();
    [[qt::signal]] void colorChanged();
    [[qt::signal]] void ratioChanged();
    [[qt::signal]] void radiusChanged();
    [[qt::signal]] void alphaChanged();

  protected:
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    friend class WindowAnimationItems<NativePaneAttention>;
    void bindClock();
    void synchronize();
    void setAlpha(float alpha);
    void sample(std::uint64_t now_ns, application::workbench::AttentionFades& fades);
    [[nodiscard]] bool eligible() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;

    ds::Option<application::workbench::PaneAttentionKey> key_;
    QColor color_ = Qt::transparent;
    qreal ratio_ = 1;
    qreal radius_ = static_cast<qreal>(gui::application::workbench::PaneDecorationGeometry::frame_radius);
    float alpha_ = 0;
    bool active_ = false;
    bool notification_pending_ = false;
    ds::Option<std::uint64_t> deadline_ns_;
    QPointer<WindowAnimationClock> clock_;
    tbc::val_self<AncestorGeometry> ancestors_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("attachment", &NativePaneAttention::attachment).withWrite(&NativePaneAttention::setAttachment).withNotify(&NativePaneAttention::attachmentChanged),
        telar::qt::property("active", &NativePaneAttention::active).withWrite(&NativePaneAttention::setActive).withNotify(&NativePaneAttention::activeChanged),
        telar::qt::property("color", &NativePaneAttention::color).withWrite(&NativePaneAttention::setColor).withNotify(&NativePaneAttention::colorChanged),
        telar::qt::property("ratio", &NativePaneAttention::ratio).withWrite(&NativePaneAttention::setRatio).withNotify(&NativePaneAttention::ratioChanged),
        telar::qt::property("radius", &NativePaneAttention::radius).withWrite(&NativePaneAttention::setRadius).withNotify(&NativePaneAttention::radiusChanged),
        telar::qt::property("alpha", &NativePaneAttention::alpha).withNotify(&NativePaneAttention::alphaChanged)
    );
  };

  // The attention rings of one window share their fades and are sampled only while the
  // window is exposed.
  class NativePaneAttention::WindowAnimationSet {
  public:
    [[tbc::hot_path]] inline void attach(NativePaneAttention& item) {
      items_.attach(item);
    }

    [[tbc::hot_path]] inline void detach(NativePaneAttention& item) {
      items_.detach(item);
    }

    bool sample(std::uint64_t timestamp, bool window_exposed, const QPointer<WindowAnimationClock>& alive);

    [[tbc::hot_path]] [[nodiscard]] inline ds::Option<std::uint64_t> deadline(std::uint64_t timestamp) const {
      return items_.deadline(timestamp);
    }

  private:
    WindowAnimationItems<NativePaneAttention> items_;
    application::workbench::AttentionFades fades_;
  };

}
