export module telar.gui.ui.app.overlays.notifications:notification_layout;

import std;
import telar.gui.qt;
import telar.tbc;
import :notifications_controller;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.models;
import telar.gui.foundation.core;
import telar.gui.application;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.base.memory.containers;
import telar.gui.ui.kit.scene;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] NotificationLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit NotificationLayout(QQuickItem* parent = nullptr);
    ~NotificationLayout() override;
    NotificationLayout(const NotificationLayout&) = delete;
    NotificationLayout& operator=(const NotificationLayout&) = delete;
    NotificationLayout(NotificationLayout&&) = delete;
    NotificationLayout& operator=(NotificationLayout&&) = delete;
    [[nodiscard]] NotificationsController* controller() const noexcept;
    void setController(NotificationsController* controller);
    [[nodiscard]] QAbstractItemModel* cards() noexcept;
    [[nodiscard]] QRectF host() const noexcept;
    [[nodiscard]] QVariantMap style() const;
    [[nodiscard]] bool eligible() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns) const;
    void sample(std::uint64_t now_ns);

    [[qt::signal]] void controllerChanged();
    [[qt::signal]] void layoutChanged();

  protected:
    void updatePolish() override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;

  private:
    // The body wraps the message stored beside it, so a content stays where it is.
    struct Content {
      Content() = default;
      ~Content() = default;
      Content(const Content&) = delete;
      Content& operator=(const Content&) = delete;
      Content(Content&&) = delete;
      Content& operator=(Content&&) = delete;

      [[tbc::hot_path]] inline void clear() {
        id = {};
        message.assign({});
        body = {};
        record.clear();
        width = 0;
        height = 0;
        action_advance = 0;
        action_line_height = 0;
      }

      application::notifications::NotificationId id{};
      runtime::FixedText<max_notification_message_bytes> message;
      tbc::val_self<application::notifications::NotificationText> body;
      QVariantMap record;
      float width = 0;
      float height = 0;
      float action_advance = 0;
      float action_line_height = 0;
    };

    void retireRemovedFocus(int first, int last);
    void invalidate();
    void scheduleLayout();
    void bindWindow();
    void rebuild();
    void refreshFonts();
    Content& content(const application::notifications::NotificationItem& item, float width);

    struct ContentRecord {
      QVariantMap record;
      float action_advance = 0;
      float action_line_height = 0;
    };

    [[nodiscard]] ContentRecord contentRecord(const application::notifications::NotificationItem& item, const Content& content) const;
    // Measures through the window's catalog and the resident fonts, apart from the layout's state.
    [[nodiscard]] static float measure(WindowFontCatalog& catalog, ResidentFonts& fonts, std::string_view text, std::uint16_t pixels, bool emphasized);

    QPointer<NotificationsController> controller_;
    QPointer<WindowAnimationClock> clock_;
    QPointer<WindowFontCatalog> catalog_;
    QMetaObject::Connection font_connection_;
    ListModel cards_;
    application::notifications::NotificationStack stack_;
    tbc::val_self<ds::Array<Content, application::notifications::NotificationCenter::capacity>> contents_;
    std::shared_ptr<const FontCollection> collection_;
    std::shared_ptr<ResidentFonts> fonts_;
    ChromeMetrics chrome_;
    application::notifications::NotificationMetrics metrics_;
    QVariantMap style_;
    QRectF host_;
    qreal density_ = 1;
    std::uint64_t now_ns_ = 0;
    std::uint64_t machine_view_ = 0;
    ds::Option<std::uint64_t> motion_end_ns_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("controller", &NotificationLayout::controller).withWrite(&NotificationLayout::setController).withNotify(&NotificationLayout::controllerChanged),
        telar::qt::property("cards", &NotificationLayout::cards).constant(),
        telar::qt::property("host", &NotificationLayout::host).withNotify(&NotificationLayout::layoutChanged),
        telar::qt::property("style", &NotificationLayout::style).withNotify(&NotificationLayout::layoutChanged)
    );
  };

}
