export module telar.gui.ui.app.panes.attachments.clipboard:clipboard_images;

import std;
import telar.gui.qt;
import telar.gui.qt.platform;
import :attachment_preview;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.gui.platform;
import telar.tbc;

export namespace telar::gui::qt {

  struct ClipboardImageJob {
    application::machines::MachineClientKey source;
    std::uint64_t runtime_generation = 0;
    std::uint64_t attachment_generation = 0;
    ClipboardCaptureRequest request;
  };

  struct ClipboardImageResult {
    ClipboardImageJob job;
    ds::Option<AttachmentCapture<ApplicationAllocator>> capture = ds::none;
    ds::Option<AttachmentPreview> preview = ds::none;
    ds::Option<platform::ClipboardImageError> failure = ds::none;
    QString error = {};
  };

  class [[qt::object]] ClipboardImages final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    // The captures allocate from memory, region `a`.
    explicit ClipboardImages(tbc::mut_a<ApplicationAllocator> memory, QObject* parent = nullptr);
    ~ClipboardImages() override;
    ClipboardImages(const ClipboardImages&) = delete;
    ClipboardImages& operator=(const ClipboardImages&) = delete;
    ClipboardImages(ClipboardImages&&) = delete;
    ClipboardImages& operator=(ClipboardImages&&) = delete;

    void capture(ClipboardImageJob job);
    [[nodiscard]] tbc::val_a<ds::Option<ClipboardImageResult>> takeResult();
    [[nodiscard]] bool busy() const noexcept;

    [[qt::signal]] void ready();
    [[qt::signal]] void queued();

  private:
    // The prepared images are allocated from memory.
    [[nodiscard]] static tbc::val_a<ClipboardImageResult> prepare(tbc::mut_a<ApplicationAllocator> memory, ClipboardImageJob job, platform::ClipboardImageSource source);
    void start(ClipboardImageJob job);
    void complete();
    void drain();
    void startQueued();

    tbc::mut_a<ApplicationAllocator> memory_;
    tbc::val_a<platform::ClipboardImageMonitor> clipboard_;
    QThreadPool worker_pool_;
    QFutureWatcher<ClipboardImageResult> task_;
    ds::Option<ClipboardImageJob> running_;
    ds::Option<ClipboardImageJob> queued_;
    tbc::val_a<ds::Option<ClipboardImageResult>> result_;
    bool busy_ = false;
  };

}
