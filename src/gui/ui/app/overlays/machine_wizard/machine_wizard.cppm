export module telar.gui.ui.app.overlays.machine_wizard;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  // The wizard that adds a machine and sets it up: pair it by the address its gateway prints,
  // choose the telar it runs, what setup brings there, apply it, sign its agents in.
  //
  // It runs the CLI and draws what it says: `telar machine add` pairs and saves the machine, and
  // `telar machine setup --events` writes each step, note and question as a JSON line, which this
  // controller answers on the command's standard input. Setup's logic stays in the CLI.
  class [[qt::object, qt_qml_named("MachineWizardController"), qt_qml_uncreatable("Use the window's machine wizard")]] MachineWizardController final : public QObject {
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

    enum class [[qt::qenum]] Step : quint8 {
      pair,
      telar,
      agents,
      apply,
      sign_in,
      ready,
    };
    explicit MachineWizardController(Store& store, QObject* parent = nullptr);
    ~MachineWizardController() override;
    MachineWizardController(const MachineWizardController&) = delete;
    MachineWizardController& operator=(const MachineWizardController&) = delete;
    MachineWizardController(MachineWizardController&&) = delete;
    MachineWizardController& operator=(MachineWizardController&&) = delete;

    [[nodiscard]] QVariantMap state() const;

    // Starts adding a machine, or setting up the saved one given; false when it cannot be set up.
    bool open(ds::Option<application::machines::MachineToken> machine);
    // The dialog closed: a command still running finishes on its own, and nobody answers it.
    void forget() noexcept;
    // The telar the wizard runs: the window's own, unless a test gives another; empty restores it.
    void setProgram(const QString& program);

    [[qt::invokable]] void setField(const QString& name, const QString& value);
    [[qt::invokable]] void setOption(const QString& name, bool value);
    [[qt::invokable]] void next();
    [[qt::invokable]] void back();
    // The help that prepares the machine and prints the command for its address; from a failed
    // pairing it starts from the address that did not answer.
    [[qt::invokable]] void openHelper(bool from_failure);
    [[qt::invokable]] void closeHelper(bool have_address);
    // Answers the question setup waits on: "true", "false", or the text asked for.
    [[qt::invokable]] void answer(const QString& value);
    [[qt::invokable]] void retry();
    [[qt::invokable]] void copyCommand() const;
    [[qt::invokable]] void openLink(const QString& url) const;

    [[qt::signal]] void changed();
    [[qt::signal]] void closeRequested();
    // The machine is ready and the person asked to see it.
    [[qt::signal]] void machineOpened(const QString& label);

  private:
    enum class Job : std::uint8_t {
      none,
      pair,
      apply,
      sign_in,
    };

    struct Wizard {
      Step step = Step::pair;
      bool existing = false;
      bool helper = false;
      bool helper_from_failure = false;
      QString address;
      QString label;
      // What setup is told the machine is: its label, or its address when it has no profile.
      QString target;
      bool label_touched = false;
      // How this Mac reaches the machine, for the help's command.
      QString reach = u"lan"_s;
      QString reach_as;
      QString listen_port;
      QString dial_port;
      bool installed = false;
      // Where the telar comes from: the release, this build, or a build on disk.
      QString source = u"release"_s;
      QString disk_path;
      bool agents = true;
      bool configuration = true;
      bool editor = true;
      // The command running or last run, and what it said.
      Job job = Job::none;
      bool running = false;
      bool paired = false;
      bool applied = false;
      bool signed_in = false;
      int exit_status = 0;
      QString failure;
      QVariantList rows;
      QVariantList logins;
      QVariantMap question;
      QJsonObject report;
    };

    [[nodiscard]] bool isOpen() const noexcept;
    [[nodiscard]] QVariantMap problems() const;
    [[nodiscard]] bool canContinue() const;
    [[nodiscard]] QString serveCommand() const;
    [[nodiscard]] QString derivedLabel() const;
    [[nodiscard]] QVariantList progress() const;
    [[nodiscard]] static QVariantList reachChoices();
    [[nodiscard]] QString telarPath() const;

    void start(Job job, const QStringList& arguments);
    void read();
    void receive(const QJsonObject& event);
    void finish(int status);
    void step(const QString& name, const QString& status, const QString& detail);

    Store& store_;
    QString program_;
    QRegularExpression address_pattern_;
    QRegularExpression label_pattern_;
    ds::Option<Wizard> wizard_;
    // The command running for the open wizard; a forgotten one runs on, unheard.
    QPointer<QProcess> process_;
    QByteArray pending_;
    QByteArray errors_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("state", &MachineWizardController::state).withNotify(&MachineWizardController::changed)
    );
  };

}
