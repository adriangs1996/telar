export module telar.gui.ui.app.panes.attachments:attachment_shelf;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.app.panes.attachments.clipboard;
import telar.gui.application;
import telar.gui.foundation.keys;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.gui.platform;

export namespace telar::gui::qt {

  struct AttachmentSource {
    application::machines::MachineClientKey source;
    std::uint64_t runtime_generation = 0;

    bool operator==(const AttachmentSource&) const = default;
  };

  struct AttachmentPrompt {
    application::machines::MachineClientKey source;
    std::uint64_t runtime_generation = 0;
    AttachmentTarget target;
    std::uint64_t attachment_generation = 0;
    AttachmentMarkerPolicy policy = AttachmentMarkerPolicy::ordered;
  };

  class [[qt::object, qt_qml_named("AttachmentShelfController"), qt_qml_uncreatable("Use the window's attachment shelf")]] AttachmentShelf final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);
    enum class QmlIsUncreatable : quint8 {
      yes = 1,
    };
    void qt_qmlMarker_uncreatable();

    explicit AttachmentShelf(ApplicationAllocator& memory, QObject* parent = nullptr);
    ~AttachmentShelf() override = default;
    AttachmentShelf(const AttachmentShelf&) = delete;
    AttachmentShelf& operator=(const AttachmentShelf&) = delete;
    AttachmentShelf(AttachmentShelf&&) = delete;
    AttachmentShelf& operator=(AttachmentShelf&&) = delete;

    [[nodiscard]] bool hoverReady() const noexcept;
    [[nodiscard]] bool hoverKnown() const noexcept;
    [[nodiscard]] QPointF hoverPosition() const noexcept;
    void observePointer(ds::Option<QPointF> position);
    void setSource(AttachmentSource source);
    void setPrompt(ds::Option<AttachmentPrompt> prompt, bool presented = true);
    void requestCapture();
    void clearPrompt(AttachmentTarget target);
    bool remove(std::uint64_t id);
    void observeKey(const TerminalKey& key, application::terminal::attachments::AttachmentMarkerScreen screen);
    void reconcile(application::terminal::attachments::AttachmentMarkerScreen screen);
    [[nodiscard]] application::terminal::attachments::AttachmentMarkerPlan removalPlan(std::uint64_t id, application::terminal::attachments::AttachmentMarkerScreen screen) const noexcept;
    [[nodiscard]] QVariantList items() const;
    [[nodiscard]] QString paneId() const;
    [[nodiscard]] QVariantMap modal() const;
    [[nodiscard]] const ds::Option<AttachmentPrompt>& prompt() const noexcept;
    [[nodiscard]] const ds::Option<AttachmentPrompt>& capturePrompt() const noexcept;
    [[nodiscard]] bool hasVisibleItems() const noexcept;
    [[qt::invokable]] QImage image(const QString& identity, bool full) const;
    [[qt::invokable]] void open(const QString& identity);
    [[qt::invokable]] void close();
    [[qt::invokable]] void dismiss(const QString& identity);

    [[qt::signal]] void changed();
    [[qt::signal]] void hoverReadyChanged();
    [[qt::signal]] void hoverRecoveryChanged();
    [[qt::signal]] void failed(const QString& message);
    [[qt::signal]] void quotaReached(platform::ClipboardImageError error);
    [[qt::signal]] void evicted(application::terminal::attachments::AttachmentEviction reason, qulonglong requested);
    [[qt::signal]] void dismissRequested(qulonglong identity);
    [[qt::signal]] void adopted(qulonglong pane_id);

  private:
    struct Delivery {
      struct SlotState {
        AttachmentPreview preview;
      };

      [[nodiscard]] SlotState create();
      void retire(SlotState& slot) noexcept;
      [[nodiscard]] static bool canRelease(const SlotState& slot) noexcept;

      ds::Option<AttachmentPreview> landing;
    };

    void complete();
    void adopt(ClipboardImageResult& result);
    [[nodiscard]] bool current(const ClipboardImageJob& job) const noexcept;

    ds::Option<QPointF> hover_pointer_;
    ds::Option<QPointF> hover_recovery_;
    bool hover_ready_ = true;
    application::terminal::attachments::ClipboardCaptureState captures_;
    ds::Option<AttachmentPrompt> prompt_;
    ds::Option<AttachmentPrompt> capture_prompt_;
    ds::Option<AttachmentSource> source_;
    Delivery delivery_;
    // The catalog delivers through the delivery stored beside it.
    tbc::val_self<application::terminal::attachments::AttachmentCatalog<ApplicationAllocator, Delivery>> catalog_;
    ClipboardImages worker_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("items", &AttachmentShelf::items).withNotify(&AttachmentShelf::changed),
        telar::qt::property("paneId", &AttachmentShelf::paneId).withNotify(&AttachmentShelf::changed),
        telar::qt::property("modal", &AttachmentShelf::modal).withNotify(&AttachmentShelf::changed),
        telar::qt::property("hoverReady", &AttachmentShelf::hoverReady).withNotify(&AttachmentShelf::hoverReadyChanged),
        telar::qt::property("hoverKnown", &AttachmentShelf::hoverKnown).withNotify(&AttachmentShelf::hoverRecoveryChanged),
        telar::qt::property("hoverPosition", &AttachmentShelf::hoverPosition).withNotify(&AttachmentShelf::hoverRecoveryChanged)
    );
  };

}
