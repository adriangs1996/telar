export module telar.gui.ui.app.overlays.machine_prompt.machine_profiles_source;

import std;
import telar.gui.qt;
import telar.gui.foundation.system;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;

export namespace telar::gui::qt {

  class [[qt::object]] MachineProfilesSource final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit MachineProfilesSource(ApplicationAllocator& memory, QObject* parent = nullptr);
    ~MachineProfilesSource() override;
    MachineProfilesSource(const MachineProfilesSource&) = delete;
    MachineProfilesSource& operator=(const MachineProfilesSource&) = delete;
    MachineProfilesSource(MachineProfilesSource&&) = delete;
    MachineProfilesSource& operator=(MachineProfilesSource&&) = delete;

    void open(const QString& path, const QString& local_label);
    void poll();
    bool edit(const application::machines::MachineEdit& edit);
    [[nodiscard]] const application::machines::MachineProfiles& profiles() const noexcept;
    [[nodiscard]] const QString& error() const noexcept;
    [[nodiscard]] bool editing() const noexcept;
    [[nodiscard]] bool editError() const noexcept;
    [[nodiscard]] bool busy() const noexcept;
    [[nodiscard]] bool loaded() const noexcept;
    [[nodiscard]] std::uint64_t revision() const noexcept;

    [[qt::signal]] void changed();
    [[qt::signal]] void failed();
    [[qt::signal]] void editingChanged();

  private:
    enum class FailureSource : std::uint8_t {
      profile,
      edit,
    };

    struct Request {
      QByteArray path;
      QByteArray local_label;
      ds::Option<system::FileStamp> known;
      ds::Option<application::machines::OwnedMachineEdit> edit;
      std::stop_token stop;
      std::uint64_t generation = 0;
      bool force = false;
    };

    struct Result {
      ds::Option<application::machines::MachineProfiles> profiles;
      ds::Option<system::FileStamp> observed;
      QString error;
      std::uint64_t generation = 0;
      bool cancelled = false;
    };

    [[nodiscard]] static Result prepare(ApplicationAllocator& memory, const Request& request);
    void start();
    void complete();
    void fail(QString message, FailureSource source = FailureSource::profile);

    ApplicationAllocator& memory_;
    QTimer poll_;
    QFutureWatcher<Result> task_;
    std::stop_source cancellation_;
    QByteArray path_;
    QByteArray local_label_;
    ds::Option<system::FileStamp> known_;
    ds::Option<application::machines::OwnedMachineEdit> pending_edit_;
    application::machines::MachineProfiles profiles_;
    QString error_;
    std::uint64_t generation_ = 0;
    std::uint64_t revision_ = 0;
    bool loaded_ = false;
    bool busy_ = false;
    bool editing_ = false;
    FailureSource failure_source_ = FailureSource::profile;
    bool reopen_pending_ = false;
    bool rescan_pending_ = false;
  };

}
