#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machine_wizard_controller.hpp"
#include "ui/kit/models/projection.hpp"
#include <QClipboard>
#include <QDesktopServices>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QStringList>
#include <QUrl>
#include <algorithm>

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  namespace {

    // The steps `machine setup` reports, in its order, with what the wizard calls each.
    struct SetupStep {
      const char* name;
      const char* title;
    };

    constexpr ds::Array setup_steps{
        SetupStep{.name = "gateway", .title = "Reach its gateway"},
        SetupStep{.name = "platform", .title = "Read its platform"},
        SetupStep{.name = "telar", .title = "Install telar"},
        SetupStep{.name = "runtime", .title = "Start the runtime"},
        SetupStep{.name = "profile", .title = "Save the machine"},
        SetupStep{.name = "agents", .title = "Install coding agents"},
        SetupStep{.name = "integrations", .title = "Install agent hooks and the editor"},
        SetupStep{.name = "configuration", .title = "Copy agent settings"},
        SetupStep{.name = "logins", .title = "Sign agents in"},
        SetupStep{.name = "check", .title = "Check a window can attach"},
    };

    // A TCP port, in decimal.
    bool validPort(const QString& text) {
      constexpr qsizetype most_digits = 5;
      constexpr unsigned highest = 65535;
      bool number = false;
      const auto port = text.toUInt(&number);

      return number && text.size() <= most_digits && port >= 1 && port <= highest;
    }

    // How this Mac reaches the machine: what the help asks for, and what to open there.
    struct Reach {
      const char* key;
      const char* name;
      const char* field;
      const char* placeholder;
      const char* open;
    };

    constexpr ds::Array reaches{
        Reach{.key = "lan", .name = "Same network", .field = "Its address on that network", .placeholder = "192.168.0.17", .open = "Open TCP %1 inbound in that machine's firewall."},
        Reach{.key = "vpn", .name = "VPN", .field = "Its name or address on the VPN", .placeholder = "box.tailnet.ts.net", .open = "Most VPNs let it through as it is. If not, allow TCP %1 on the VPN's interface there."},
        Reach{.key = "public", .name = "Public address", .field = "Its public address or DNS name", .placeholder = "203.0.113.7", .open = "Allow inbound TCP %1 in its firewall or security group, ideally from your IP only."},
        Reach{.key = "forward", .name = "Published or forwarded port", .field = "Address this Mac dials", .placeholder = "203.0.113.7", .open = "Map the port this Mac dials to %1 on that machine: docker run -p %2:%1, or the router's forward."},
    };

    const Reach& reachOf(const QString& key) {
      const auto* found = std::ranges::find_if(reaches, [&](const Reach& reach) {
        return key == QLatin1String(reach.key);
      });

      return found == reaches.end() ? reaches[0] : *found;
    }

    QString lastLines(const QByteArray& text) {
      const auto trimmed = QString::fromUtf8(text).trimmed();
      constexpr qsizetype most = 600;

      return trimmed.size() > most ? trimmed.right(most) : trimmed;
    }

  }

  MachineWizardController::MachineWizardController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store),
        program_(toQString(system::runtime_endpoint::program().view())),
        // The address `telar server pair` prints: telar://HOST:PORT#KEY, with .CODE while it pairs.
        address_pattern_(QStringLiteral(R"(^telar://(\[[0-9A-Fa-f:]+\]|[^\s:#/\[\]]+):(\d{1,5})#([0-9a-f]{64})(?:\.([0-9a-f]{32}))?$)")),
        label_pattern_(QStringLiteral(R"(^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$)")) {}

  MachineWizardController::~MachineWizardController() {
    forget();
  }

  void MachineWizardController::setProgram(const QString& program) {
    program_ = program.isEmpty() ? toQString(system::runtime_endpoint::program().view()) : program;
  }

  bool MachineWizardController::isOpen() const noexcept {
    return store_.dialog().kind == Store::Dialog::machine_wizard && wizard_.hasValue();
  }

  bool MachineWizardController::open(ds::Option<application::machines::MachineToken> machine) {
    if (machine && (!store_.machines().contains(*machine) || machine->slot == application::machines::Machines::local_slot)) {
      return false;
    }

    forget();
    wizard_.emplace();
    if (machine) {
      const auto& row = store_.machines().row(machine->slot);
      auto& wizard = wizard_.getMut();

      wizard.existing = true;
      wizard.paired = true;
      wizard.label = toQString(row.label.view());
      wizard.address = toQString(row.destination.view());
      wizard.target = row.id.value() == 0 ? wizard.address : wizard.label;
      wizard.step = Step::telar;
    }

    return true;
  }

  void MachineWizardController::forget() noexcept {
    if (process_) {
      process_->disconnect(this);
      // Setup reads its answers here; without them each question has none and it ends.
      process_->closeWriteChannel();
      process_.clear();
    }

    pending_.clear();
    errors_.clear();
    wizard_.reset();
  }

  QString MachineWizardController::derivedLabel() const {
    const auto match = address_pattern_.match(wizard_->address.trimmed());
    if (!match.hasMatch()) {
      return {};
    }

    // As setup derives one: the host, its bytes outside a label's made dashes.
    auto host = match.captured(1).remove(QLatin1Char('[')).remove(QLatin1Char(']')).left(static_cast<qsizetype>(application::machines::MachineLimits::label_bytes));

    for (auto& character : host) {
      const bool kept = character.isLetterOrNumber() && character.unicode() < 128;
      if (!kept && character != QLatin1Char('.') && character != QLatin1Char('_') && character != QLatin1Char('-')) {
        character = QLatin1Char('-');
      }
    }

    return host;
  }

  void MachineWizardController::setField(const QString& name, const QString& value) { // NOLINT(bugprone-easily-swappable-parameters): QML names the field and gives what was typed in it
    if (!isOpen()) {
      return;
    }

    auto& wizard = wizard_.getMut();

    if (name == QLatin1String("address")) {
      wizard.address = value.trimmed();
      wizard.failure.clear();
      if (!wizard.label_touched) {
        wizard.label = derivedLabel();
      }
    } else if (name == QLatin1String("label")) {
      wizard.label = value.trimmed();
      wizard.label_touched = true;
    } else if (name == QLatin1String("reach")) {
      wizard.reach = reachOf(value).key;
    } else if (name == QLatin1String("reachAs")) {
      wizard.reach_as = value.trimmed();
    } else if (name == QLatin1String("listenPort")) {
      wizard.listen_port = value.trimmed();
    } else if (name == QLatin1String("dialPort")) {
      wizard.dial_port = value.trimmed();
    } else if (name == QLatin1String("source")) {
      wizard.source = value;
    } else if (name == QLatin1String("diskPath")) {
      wizard.disk_path = value.trimmed();
    }

    emit changed();
  }

  void MachineWizardController::setOption(const QString& name, bool value) {
    if (!isOpen()) {
      return;
    }

    auto& wizard = wizard_.getMut();

    if (name == QLatin1String("agents")) {
      wizard.agents = value;
    } else if (name == QLatin1String("configuration")) {
      wizard.configuration = value;
    } else if (name == QLatin1String("editor")) {
      wizard.editor = value;
    } else if (name == QLatin1String("installed")) {
      wizard.installed = value;
    }

    emit changed();
  }

  QVariantMap MachineWizardController::problems() const {
    QVariantMap found;
    const auto& wizard = *wizard_;

    if (wizard.step == Step::pair && wizard.helper) {
      if (wizard.reach_as.isEmpty()) {
        found.insert(QStringLiteral("reachAs"), QStringLiteral("Required: the machine's host name rarely resolves from here"));
      }

      if (!wizard.listen_port.isEmpty() && !validPort(wizard.listen_port)) {
        found.insert(QStringLiteral("listenPort"), QStringLiteral("A port is 1 to 65535"));
      }

      if (wizard.reach == QLatin1String("forward") && !validPort(wizard.dial_port)) {
        found.insert(QStringLiteral("dialPort"), QStringLiteral("The port this Mac dials, 1 to 65535"));
      }
    } else if (wizard.step == Step::pair && !wizard.paired) {
      if (!wizard.address.isEmpty() && !address_pattern_.match(wizard.address).hasMatch()) {
        found.insert(QStringLiteral("address"), QStringLiteral("Not an address telar prints. Paste the whole line, including what follows #"));
      }

      const auto label = wizard.label.toUtf8();
      const bool taken = !label.isEmpty() && std::ranges::any_of(store_.machines().rows(), [&](const auto& row) {
        return row.label.view() == std::string_view{label.constData(), static_cast<std::size_t>(label.size())};
      });

      if (!wizard.label.isEmpty() && !label_pattern_.match(wizard.label).hasMatch()) {
        found.insert(QStringLiteral("label"), QStringLiteral("1 to 32 letters, digits, '.', '_' or '-', starting with a letter or a digit"));
      } else if (taken) {
        found.insert(QStringLiteral("label"), QStringLiteral("“%1” is already a machine of this window").arg(wizard.label));
      }
    } else if (wizard.step == Step::telar && wizard.source == QLatin1String("disk") && wizard.disk_path.isEmpty()) {
      found.insert(QStringLiteral("diskPath"), QStringLiteral("The telar built for that machine, with its companions beside it"));
    }

    return found;
  }

  bool MachineWizardController::canContinue() const {
    if (!wizard_) {
      return false;
    }

    const auto& wizard = *wizard_;

    // Each agent can wait: a login left for later keeps setup running there until it ends, and
    // the wizard goes on without it.
    if (wizard.step == Step::sign_in) {
      return wizard.question.isEmpty();
    }

    if (wizard.running) {
      return false;
    }

    switch (wizard.step) {
    case Step::pair:
      if (wizard.helper) {
        return problems().isEmpty();
      }

      return wizard.paired || (problems().isEmpty() && !wizard.address.isEmpty() && !wizard.label.isEmpty());
    case Step::telar:
    case Step::agents:
      return problems().isEmpty();
    case Step::apply:
      return wizard.applied;
    case Step::sign_in:
    case Step::ready:
      return true;
    }

    return false;
  }

  QString MachineWizardController::serveCommand() const {
    const auto& wizard = *wizard_;
    const auto listen = !wizard.listen_port.isEmpty() && wizard.listen_port != QLatin1String("8352") ? QStringLiteral(":") + wizard.listen_port : QString{};
    const auto host = wizard.reach_as.isEmpty() ? QString{} : QStringLiteral(" --host ") + wizard.reach_as;
    const auto dial = wizard.reach == QLatin1String("forward") && !wizard.dial_port.isEmpty() ? QStringLiteral(" --port ") + wizard.dial_port : QString{};

    if (wizard.installed) {
      return QStringLiteral("telar server enable") + (listen.isEmpty() ? QString{} : QStringLiteral(" ") + listen) + host + dial;
    }

    return QStringLiteral("curl -fsSL https://github.com/adriangs1996/telar/releases/latest/download/install.sh | sh -s -- --headless --serve") + (listen.isEmpty() ? QString{} : QStringLiteral(" --listen ") + listen) + host + dial;
  }

  void MachineWizardController::next() {
    if (!isOpen() || !canContinue()) {
      return;
    }

    auto& wizard = wizard_.getMut();

    switch (wizard.step) {
    case Step::pair:
      if (wizard.helper) {
        closeHelper(true);
        return;
      }

      if (!wizard.paired) {
        start(Job::pair, {QStringLiteral("machine"), QStringLiteral("add"), wizard.label, wizard.address});
        return;
      }

      wizard.step = Step::telar;
      break;
    case Step::telar:
      wizard.step = Step::agents;
      break;
    case Step::agents: {
      QStringList arguments{QStringLiteral("machine"), QStringLiteral("setup"), wizard.target.isEmpty() ? wizard.label : wizard.target};
      QStringList skipped{QStringLiteral("login")};

      if (wizard.source == QLatin1String("build")) {
        arguments << QStringLiteral("--binary") << program_;
      } else if (wizard.source == QLatin1String("disk")) {
        arguments << QStringLiteral("--binary") << wizard.disk_path;
      }

      if (!wizard.agents) {
        skipped << QStringLiteral("agents");
      }

      if (!wizard.configuration) {
        skipped << QStringLiteral("config");
      }

      if (!wizard.editor) {
        skipped << QStringLiteral("editor");
      }

      arguments << QStringLiteral("--skip") << skipped.join(QLatin1Char(',')) << QStringLiteral("--events");
      wizard.step = Step::apply;
      start(Job::apply, arguments);
      return;
    }
    case Step::apply:
      wizard.step = Step::sign_in;
      start(Job::sign_in, {QStringLiteral("machine"), QStringLiteral("setup"), wizard.target.isEmpty() ? wizard.label : wizard.target, QStringLiteral("--skip"), QStringLiteral("agents,config,editor"), QStringLiteral("--events")});
      return;
    case Step::sign_in:
      wizard.step = Step::ready;
      break;
    case Step::ready: {
      const auto label = wizard.label;

      emit machineOpened(label);
      emit closeRequested();
      return;
    }
    }

    emit changed();
  }

  void MachineWizardController::back() {
    if (!isOpen()) {
      return;
    }

    auto& wizard = wizard_.getMut();

    if (wizard.helper) {
      closeHelper(false);
      return;
    }

    const bool first = wizard.step == Step::pair || (wizard.existing && wizard.step == Step::telar);
    // What setup did there stays done: from Apply on, the wizard only goes forward.
    if (wizard.running || first || wizard.step >= Step::apply) {
      return;
    }

    wizard.step = static_cast<Step>(static_cast<int>(wizard.step) - 1);
    if (wizard.step == Step::pair && wizard.paired) {
      wizard.step = Step::telar;
    }

    emit changed();
  }

  void MachineWizardController::openHelper(bool from_failure) {
    if (!isOpen()) {
      return;
    }

    auto& wizard = wizard_.getMut();

    if (from_failure) {
      if (const auto match = address_pattern_.match(wizard.address); match.hasMatch()) {
        wizard.reach_as = match.captured(1);
        if (match.captured(2) != (wizard.listen_port.isEmpty() ? QStringLiteral("8352") : wizard.listen_port)) {
          wizard.reach = QStringLiteral("forward");
          wizard.dial_port = match.captured(2);
        }
      }
    }

    wizard.helper = true;
    wizard.helper_from_failure = from_failure;
    emit changed();
  }

  void MachineWizardController::closeHelper(bool have_address) {
    if (!isOpen()) {
      return;
    }

    auto& wizard = wizard_.getMut();

    wizard.helper = false;
    // The address the machine prints now is the one to pair with; the one that failed is not.
    if (have_address && wizard.helper_from_failure) {
      wizard.address.clear();
      wizard.failure.clear();
    }

    emit changed();
  }

  void MachineWizardController::start(Job job, const QStringList& arguments) {
    auto& wizard = wizard_.getMut();
    auto* process = new QProcess(this); // NOLINT(cppcoreguidelines-owning-memory): its parent, this controller, owns it, and it deletes itself once it ends

    wizard.job = job;
    wizard.running = true;
    wizard.failure.clear();
    wizard.question.clear();
    wizard.exit_status = 0;
    wizard.rows.clear();
    if (job == Job::sign_in) {
      wizard.logins.clear();
    }

    pending_.clear();
    errors_.clear();
    process_ = process;
    connect(process, &QProcess::readyReadStandardOutput, this, [this, process] {
      if (process == process_) {
        read();
      }
    });

    connect(process, &QProcess::readyReadStandardError, this, [this, process] {
      if (process == process_) {
        errors_.append(process->readAllStandardError());
        constexpr qsizetype kept = 4096;

        if (errors_.size() > kept) {
          errors_ = errors_.right(kept);
        }
      }
    });

    connect(process, &QProcess::finished, this, [this, process](int status, QProcess::ExitStatus exit) {
      if (process == process_) {
        read();
        finish(exit == QProcess::NormalExit ? status : -1);
      }
    });

    connect(process, &QProcess::errorOccurred, this, [this, process](QProcess::ProcessError error) {
      if (error == QProcess::FailedToStart && process == process_) {
        errors_ = QByteArrayLiteral("telar could not start: ") + process->program().toUtf8();
        finish(-1);
      }
    });

    connect(process, &QProcess::finished, process, &QObject::deleteLater);
    process->start(program_, arguments);
    emit changed();
  }

  void MachineWizardController::read() {
    if (!process_) {
      return;
    }

    pending_.append(process_->readAllStandardOutput());
    for (auto end = pending_.indexOf('\n'); end >= 0; end = pending_.indexOf('\n')) {
      const auto line = pending_.left(end);

      pending_.remove(0, end + 1);
      const auto document = QJsonDocument::fromJson(line);
      if (document.isObject() && wizard_) {
        receive(document.object());
      }
    }

    emit changed();
  }

  void MachineWizardController::step(const QString& name, const QString& status, const QString& detail) {
    auto& rows = wizard_.getMut().rows;

    for (auto& row : rows) {
      auto map = row.toMap();
      if (map.value(QStringLiteral("step")).toString() == name) {
        if (!status.isEmpty()) {
          map.insert(QStringLiteral("status"), status);
          map.insert(QStringLiteral("detail"), detail);
        }

        row = map;
        return;
      }
    }

    rows.append(QVariantMap{{QStringLiteral("step"), name}, {QStringLiteral("status"), status}, {QStringLiteral("detail"), detail}, {QStringLiteral("notes"), QStringList{}}});
  }

  void MachineWizardController::receive(const QJsonObject& event) {
    const auto kind = event.value(QStringLiteral("event")).toString();

    if (kind == QLatin1String("step")) {
      step(event.value(QStringLiteral("step")).toString(), event.value(QStringLiteral("status")).toString(), event.value(QStringLiteral("detail")).toString());
      return;
    }

    if (kind == QLatin1String("note")) {
      const auto name = event.value(QStringLiteral("step")).toString();

      // The step's row first, which a note may come before; then the note on it.
      step(name, {}, {});
      for (auto& row : wizard_.getMut().rows) {
        auto map = row.toMap();
        if (map.value(QStringLiteral("step")).toString() == name) {
          auto notes = map.value(QStringLiteral("notes")).toStringList();

          notes << event.value(QStringLiteral("text")).toString();
          map.insert(QStringLiteral("notes"), notes);
          row = map;
        }
      }

      return;
    }

    auto& wizard = wizard_.getMut();

    if (kind == QLatin1String("login")) {
      wizard.logins.append(QVariantMap{
          {QStringLiteral("agent"), event.value(QStringLiteral("agent")).toString()},
          {QStringLiteral("url"), event.value(QStringLiteral("url")).toString()},
          {QStringLiteral("code"), event.value(QStringLiteral("code")).toString()},
      });
    } else if (kind == QLatin1String("question")) {
      wizard.question = event.toVariantMap();
    } else if (kind == QLatin1String("done") && wizard.job == Job::apply) {
      // The report of the setup that placed telar: Ready shows where it put it.
      wizard.report = event.value(QStringLiteral("report")).toObject();
    }
  }

  void MachineWizardController::finish(int status) {
    if (!wizard_) {
      return;
    }

    auto& wizard = wizard_.getMut();

    wizard.running = false;
    wizard.exit_status = status;
    wizard.question.clear();
    switch (wizard.job) {
    case Job::pair:
      wizard.paired = status == 0;
      if (wizard.paired) {
        wizard.label_touched = true;
      } else {
        wizard.failure = lastLines(errors_);
      }

      break;
    case Job::apply:
      wizard.applied = status == 0;
      if (!wizard.applied) {
        const auto failed = std::ranges::find_if(wizard.rows, [](const QVariant& row) {
          return row.toMap().value(QStringLiteral("status")).toString() == QLatin1String("failed");
        });

        wizard.failure = failed != wizard.rows.end() ? failed->toMap().value(QStringLiteral("detail")).toString() : lastLines(errors_);
      }

      break;
    case Job::sign_in:
      wizard.signed_in = true;
      break;
    case Job::none:
      break;
    }

    process_.clear();
    emit changed();
  }

  void MachineWizardController::answer(const QString& value) {
    if (!isOpen() || !process_ || wizard_->question.isEmpty()) {
      return;
    }

    auto& wizard = wizard_.getMut();
    const auto kind = wizard.question.value(QStringLiteral("kind")).toString();
    QJsonObject reply{{QStringLiteral("answer"), kind}};

    if (value == QLatin1String("true") || value == QLatin1String("false")) {
      reply.insert(QStringLiteral("value"), value == QLatin1String("true"));
    } else {
      reply.insert(QStringLiteral("value"), value);
    }

    process_->write(QJsonDocument{reply}.toJson(QJsonDocument::Compact) + '\n');
    wizard.question.clear();
    emit changed();
  }

  void MachineWizardController::retry() {
    if (!isOpen() || wizard_->running) {
      return;
    }

    auto& wizard = wizard_.getMut();

    if (wizard.step == Step::apply) {
      wizard.step = Step::agents;
      next();
    } else if (wizard.step == Step::sign_in) {
      wizard.step = Step::apply;
      wizard.applied = true;
      next();
    }
  }

  void MachineWizardController::copyCommand() const {
    if (wizard_) {
      QGuiApplication::clipboard()->setText(serveCommand());
    }
  }

  void MachineWizardController::openLink(const QString& url) const { // NOLINT(readability-convert-member-functions-to-static): QML calls it on the instance, and moc has no static invokables
    const QUrl link{url};

    if (link.scheme() == QLatin1String("https")) {
      QDesktopServices::openUrl(link);
    }
  }

  // The rows setup reports, in its order: those it reported, then those still to come, the first
  // of which runs while setup does.
  QVariantList MachineWizardController::progress() const {
    const auto& wizard = *wizard_;
    QVariantList plan;
    const bool signing = wizard.step == Step::sign_in;
    bool running_marked = false;

    for (const auto& setup_step : setup_steps) {
      const auto name = QLatin1String(setup_step.name);
      const bool shown = signing ? name == QLatin1String("logins") : name != QLatin1String("logins");
      if (!shown) {
        continue;
      }

      QVariantMap row{{QStringLiteral("step"), QString{name}}, {QStringLiteral("title"), QString::fromLatin1(setup_step.title)}, {QStringLiteral("status"), QString{}}, {QStringLiteral("detail"), QString{}}, {QStringLiteral("notes"), QStringList{}}};

      for (const auto& reported : wizard.rows) {
        const auto map = reported.toMap();
        if (map.value(QStringLiteral("step")).toString() == name) {
          row.insert(QStringLiteral("status"), map.value(QStringLiteral("status")));
          row.insert(QStringLiteral("detail"), map.value(QStringLiteral("detail")));
          row.insert(QStringLiteral("notes"), map.value(QStringLiteral("notes")));
        }
      }

      if (wizard.running && !running_marked && row.value(QStringLiteral("status")).toString().isEmpty()) {
        row.insert(QStringLiteral("status"), QStringLiteral("running"));
        running_marked = true;
      }

      plan.append(row);
    }

    return plan;
  }

  QVariantList MachineWizardController::reachChoices() {
    QVariantList choices;

    for (const auto& choice : reaches) {
      choices.append(QVariantMap{{QStringLiteral("key"), QString::fromLatin1(choice.key)}, {QStringLiteral("name"), QString::fromLatin1(choice.name)}});
    }

    return choices;
  }

  // Where the setup that placed telar says it put it: its profile step names it.
  QString MachineWizardController::telarPath() const {
    const auto mark = QStringLiteral("telar at ");
    const auto steps = wizard_->report.value(QStringLiteral("steps")).toArray();

    for (const QJsonValue reported : steps) {
      const auto step = reported.toObject();
      if (step.value(QStringLiteral("step")).toString() == QLatin1String("profile")) {
        const auto detail = step.value(QStringLiteral("detail")).toString();
        const auto marked = detail.lastIndexOf(mark);

        return marked < 0 ? QString{} : detail.mid(marked + mark.size());
      }
    }

    return {};
  }

  QVariantMap MachineWizardController::state() const {
    if (!wizard_) {
      return {{QStringLiteral("open"), false}};
    }

    const auto& wizard = *wizard_;
    const auto match = address_pattern_.match(wizard.address);
    QVariantMap parsed;

    if (match.hasMatch()) {
      // The key as it is told apart: its first and last digits.
      constexpr qsizetype key_head = 8;
      constexpr qsizetype key_tail = 4;
      const auto key = match.captured(3);

      parsed = {
          {QStringLiteral("host"), match.captured(1)},
          {QStringLiteral("port"), match.captured(2)},
          {QStringLiteral("key"), key.left(key_head) + QStringLiteral("…") + key.right(key_tail)},
          {QStringLiteral("code"), !match.captured(4).isEmpty()},
      };
    }

    const auto& reach = reachOf(wizard.reach);
    const auto listen = wizard.listen_port.isEmpty() ? QStringLiteral("8352") : wizard.listen_port;

    return {
        {QStringLiteral("open"), true},
        {QStringLiteral("step"), static_cast<int>(wizard.step)},
        {QStringLiteral("steps"), QStringList{QStringLiteral("Pair"), QStringLiteral("Telar"), QStringLiteral("Agents"), QStringLiteral("Apply"), QStringLiteral("Sign in"), QStringLiteral("Ready")}},
        {QStringLiteral("existing"), wizard.existing},
        {QStringLiteral("helper"), wizard.helper},
        {QStringLiteral("address"), wizard.address},
        {QStringLiteral("parsed"), parsed},
        {QStringLiteral("label"), wizard.label},
        {QStringLiteral("localName"), toQString(store_.machines().row(application::machines::Machines::local_slot).label.view())},
        {QStringLiteral("reach"), wizard.reach},
        {QStringLiteral("reaches"), reachChoices()},
        {QStringLiteral("reachField"), QString::fromLatin1(reach.field)},
        {QStringLiteral("reachPlaceholder"), QString::fromLatin1(reach.placeholder)},
        {QStringLiteral("openLine"), QString::fromLatin1(reach.open).replace(QStringLiteral("%1"), listen).replace(QStringLiteral("%2"), wizard.dial_port.isEmpty() ? QStringLiteral("PORT") : wizard.dial_port)},
        {QStringLiteral("reachAs"), wizard.reach_as},
        {QStringLiteral("listenPort"), wizard.listen_port},
        {QStringLiteral("dialPort"), wizard.dial_port},
        {QStringLiteral("installed"), wizard.installed},
        {QStringLiteral("command"), serveCommand()},
        {QStringLiteral("source"), wizard.source},
        {QStringLiteral("diskPath"), wizard.disk_path},
        {QStringLiteral("thisBuild"), program_},
        {QStringLiteral("agents"), wizard.agents},
        {QStringLiteral("configuration"), wizard.configuration},
        {QStringLiteral("editor"), wizard.editor},
        {QStringLiteral("running"), wizard.running},
        {QStringLiteral("paired"), wizard.paired},
        {QStringLiteral("applied"), wizard.applied},
        {QStringLiteral("signedIn"), wizard.signed_in},
        {QStringLiteral("failure"), wizard.failure},
        {QStringLiteral("rows"), progress()},
        {QStringLiteral("logins"), wizard.logins},
        {QStringLiteral("question"), wizard.question},
        {QStringLiteral("problems"), problems()},
        {QStringLiteral("canContinue"), canContinue()},
        {QStringLiteral("destination"), wizard.report.value(QStringLiteral("destination")).toString(wizard.address)},
        {QStringLiteral("telarPath"), telarPath()},
    };
  }

}
