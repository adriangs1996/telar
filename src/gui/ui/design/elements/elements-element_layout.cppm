export module telar.gui.ui.design.elements:element_layout;

import std;
import telar.gui.qt;
import telar.base.ds;
import telar.gui.ui.kit.scene;

export namespace telar::gui::qt {

  // Places the children of one mod element: a row, a column or a stack. Each child is an
  // item with an `element` record; the layout reads its size, grow and pose from it and, for
  // children with an `id` and a `transition`, eases between poses on the window clock.
  class [[qt::object, qt::qml_element]] ElementLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    enum class [[qt::qenum]] Direction : std::uint8_t {
      row,
      column,
      stack,
    };
    // The curve a child eases its pose along; an element's `easing` code picks it.
    enum class Easing : std::uint8_t {
      out,
      linear,
      in_out,
    };

    explicit ElementLayout(QQuickItem* parent = nullptr);
    ~ElementLayout() override;
    ElementLayout(const ElementLayout&) = delete;
    ElementLayout& operator=(const ElementLayout&) = delete;
    ElementLayout(ElementLayout&&) = delete;
    ElementLayout& operator=(ElementLayout&&) = delete;

    [[nodiscard]] int direction() const noexcept;
    void setDirection(int direction);
    [[nodiscard]] qreal gap() const noexcept;
    void setGap(qreal gap);
    [[nodiscard]] QVariantList padding() const;
    void setPadding(const QVariantList& padding);
    [[nodiscard]] int align() const noexcept;
    void setAlign(int align);
    [[nodiscard]] int justify() const noexcept;
    void setJustify(int justify);
    [[nodiscard]] qreal ratio() const noexcept;
    void setRatio(qreal ratio);

    [[nodiscard]] bool eligible() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;
    void sample(std::uint64_t now_ns);

    [[qt::signal]] void layoutChanged();

  private:
    [[qt::slot]] void relayout();

  protected:
    void itemChange(ItemChange change, const ItemChangeData& value) override;
    void geometryChange(const QRectF& next, const QRectF& previous) override;
    void updatePolish() override;

  private:
    struct Pose {
      qreal x = 0;
      qreal y = 0;
      qreal rotation = 0;
      qreal scale = 1;
      qreal opacity = 1;
    };

    struct Motion {
      Pose from;
      Pose to;
      Pose shown;
      std::uint64_t start_ns = 0;
      std::uint64_t duration_ns = 0;
      Easing easing = Easing::out;
      bool seen = false;
    };

    void watch(QQuickItem* child);
    void bindClock();
    [[nodiscard]] Pose animate(const QString& key, const Pose& target, qreal transition_ms, Easing easing, std::uint64_t now_ns);

    int direction_ = std::to_underlying(Direction::row);
    qreal gap_ = 0;
    ds::Array<qreal, 4> padding_{};
    int align_ = 0;
    int justify_ = 0;
    qreal ratio_ = 1;
    QHash<QString, Motion> motions_;
    QPointer<WindowAnimationClock> clock_;
    ds::Option<std::uint64_t> next_sample_ns_;
    bool frame_requested_ = false;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("direction", &ElementLayout::direction).withWrite(&ElementLayout::setDirection).withNotify(&ElementLayout::layoutChanged),
        telar::qt::property("gap", &ElementLayout::gap).withWrite(&ElementLayout::setGap).withNotify(&ElementLayout::layoutChanged),
        telar::qt::property("padding", &ElementLayout::padding).withWrite(&ElementLayout::setPadding).withNotify(&ElementLayout::layoutChanged),
        telar::qt::property("align", &ElementLayout::align).withWrite(&ElementLayout::setAlign).withNotify(&ElementLayout::layoutChanged),
        telar::qt::property("justify", &ElementLayout::justify).withWrite(&ElementLayout::setJustify).withNotify(&ElementLayout::layoutChanged),
        telar::qt::property("ratio", &ElementLayout::ratio).withWrite(&ElementLayout::setRatio).withNotify(&ElementLayout::layoutChanged)
    );
  };

}
