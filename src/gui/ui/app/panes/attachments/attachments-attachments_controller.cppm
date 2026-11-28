export module telar.gui.ui.app.panes.attachments:attachments_controller;

import std;
import telar.gui.qt;
import :attachment_shelf;
import telar.gui.ui.kit.store;
import telar.gui.foundation.core;
import telar.gui.foundation.keys;
import telar.gui.foundation.model;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  // The clipboard images pasted into an agent's prompt on this computer: the shelf under the
  // focused pane that lists them, and the modal that shows one.
  //
  // Images are only taken on the local machine, so the shelf follows the local session; it
  // reserves rows under the agent's pane and writes the markers the agent reads. It reads the
  // store and the display the window pushes. The window takes the input away from the panes
  // while the modal is open.
  class [[qt::object, qt_qml_named("AttachmentsController"), qt_qml_uncreatable("Use the window's attachments")]] AttachmentsController final : public QObject {
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

    AttachmentsController(Store& store, ApplicationAllocator& memory, QObject* parent = nullptr);
    ~AttachmentsController() override = default;
    AttachmentsController(const AttachmentsController&) = delete;
    AttachmentsController& operator=(const AttachmentsController&) = delete;
    AttachmentsController(AttachmentsController&&) = delete;
    AttachmentsController& operator=(AttachmentsController&&) = delete;

    [[nodiscard]] AttachmentShelf* shelf() noexcept;
    [[nodiscard]] QVariantMap geometry() const;
    [[nodiscard]] QVariantMap modalGeometry() const;
    [[nodiscard]] bool modalOpen() const noexcept;

    // Follows the local session's focused agent: its prompt, and the rows the shelf reserves.
    void synchronize();
    // Notifies the geometries when what they are measured from moved.
    void publishGeometry();
    void setDisplay(const application::window::DisplayMetrics& display);
    // A key the window received while the modal is open belongs to it.
    bool interceptKey(QKeyEvent& event);
    // A key a pane received: Ctrl+V takes the clipboard's image, and editing keys move the
    // markers the shelf tracks.
    void key(std::uint64_t pane_id, const TerminalKey& key);
    // The local pane drew a frame: the markers the agent reads are read again from it.
    void reconcileFrame(std::uint64_t pane_id);

    [[qt::signal]] void geometryChanged();
    // The shelf or its modal changed what it shows.
    [[qt::signal]] void changed();
    // The modal opened or closed; while it is open the panes take no input.
    [[qt::signal]] void modalChanged(bool open);
    [[qt::signal]] void failed(const QString& message);

  private:
    // What the geometries are measured from.
    struct Inputs {
      WorkbenchGeometry host;
      Rect terminal;
      CellRectangle reserved;
      double density = 1;
      bool shelf = false;

      [[tbc::hot_path]] inline bool operator==(const Inputs& other) const {
        return host == other.host && terminal == other.terminal && reserved == other.reserved && std::equal_to<>{}(density, other.density) && shelf == other.shelf;
      }
    };

    void shelfChanged();
    void dismiss(std::uint64_t identity);

    Store& store_;
    AttachmentShelf shelf_;
    bool modal_open_ = false;
    ds::Option<Inputs> published_;
    application::window::DisplayMetrics display_{};

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("shelf", &AttachmentsController::shelf).constant(),
        telar::qt::property("geometry", &AttachmentsController::geometry).withNotify(&AttachmentsController::geometryChanged),
        telar::qt::property("modalGeometry", &AttachmentsController::modalGeometry).withNotify(&AttachmentsController::geometryChanged)
    );
  };

}
