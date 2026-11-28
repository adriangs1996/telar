export module telar.gui.ui.design.controls:modal_reveal_layout;

import std;
import telar.gui.qt;
import telar.gui.foundation.drawing;
import telar.base.ds;
import telar.gui.ui.kit.scene;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] ModalRevealLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit ModalRevealLayout(QQuickItem* parent = nullptr);
    ~ModalRevealLayout() override;
    ModalRevealLayout(const ModalRevealLayout&) = delete;
    ModalRevealLayout& operator=(const ModalRevealLayout&) = delete;
    ModalRevealLayout(ModalRevealLayout&&) = delete;
    ModalRevealLayout& operator=(ModalRevealLayout&&) = delete;
    [[nodiscard]] QString generation() const;
    void setGeneration(const QString& generation);
    [[nodiscard]] bool active() const noexcept;
    void setActive(bool active);
    [[nodiscard]] qreal reveal() const noexcept;

    [[qt::signal]] void generationChanged();
    [[qt::signal]] void activeChanged();
    [[qt::signal]] void frameChanged();

  protected:
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    friend class WindowAnimationItems<ModalRevealLayout>;
    [[nodiscard]] bool eligible() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;
    void sample(std::uint64_t now_ns);
    void prepareFrame();
    void bindClock();
    void synchronize();

    QString generation_;
    ds::Option<std::uint64_t> identity_;
    QPointer<WindowAnimationClock> clock_;
    QMetaObject::Connection frame_connection_;
    ModalMotion motion_;
    ds::Option<std::uint64_t> next_sample_ns_;
    qreal reveal_ = 1;
    bool active_ = false;
    bool dirty_ = true;
    bool frame_requested_ = false;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("generation", &ModalRevealLayout::generation).withWrite(&ModalRevealLayout::setGeneration).withNotify(&ModalRevealLayout::generationChanged),
        telar::qt::property("active", &ModalRevealLayout::active).withWrite(&ModalRevealLayout::setActive).withNotify(&ModalRevealLayout::activeChanged),
        telar::qt::property("reveal", &ModalRevealLayout::reveal).withNotify(&ModalRevealLayout::frameChanged)
    );
  };

}
