module telar.gui.ui.kit.links;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.machines;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.process;
import telar.gui.application;
import telar.gui.foundation.system;
import telar.base.ds;
import telar.base.text;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  LinksController::LinksController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store),
        opener_(*this) {}

  bool LinksController::open(const application::terminal::links::LinkTarget& target, ds::Option<std::uint64_t> source_id) {
    try {
      if (target.scheme() == application::terminal::links::LinkScheme::file || target.scheme() == application::terminal::links::LinkScheme::path) {
        const ProcessEnvironment environment;
        // A copy, as Rust clones it: opening the file borrows the session it is configured in.
        const auto configured = store_.session().configuration.editor;
        const auto executable = configured.view().empty() ? environment("EDITOR").valueOr(std::string_view{}) : configured.view();

        application::terminal::links::openFile(store_.sessionMut(), application::terminal::links::FilePath::parse(target), executable, environment, source_id);
      } else if (!openForwarded(target)) {
        opener_.request(target, store_.client(store_.machines().active()).key);
      }
    } catch (const std::exception& error) {
      openingFailed(u"Could not open link: "_s + toQString(error.what()));

      return false;
    }

    return true;
  }

  bool LinksController::openForwarded(const application::terminal::links::LinkTarget& target) {
    const auto slot = store_.machines().active();
    const auto link = application::terminal::links::LocalPortLink::parse(target);
    const auto destination = store_.machines().row(slot).destination.view();

    // A link on this machine names a port of this machine: the browser reaches it as it is.
    if (slot == application::machines::Machines::local_slot || destination.empty() || !link) {
      return false;
    }

    const auto key = store_.client(slot).key;
    ds::Option<std::size_t> vacant;

    for (std::size_t index = 0; index < forwards_.size(); ++index) {
      auto& forward = forwards_.atMut(index);
      if (!forward) {
        vacant = vacant ? vacant : ds::Option{index};
        continue;
      }

      if (forward->remote != link->port() || std::string_view{forward->destination.constData(), static_cast<std::size_t>(forward->destination.size())} != destination) {
        continue;
      }

      // The port is already forwarded, or about to be: the link opens through it.
      if (forward->local == 0) {
        forward->pending = target;
        forward->source = key;
      } else if (const auto rewritten = link->through(forward->local)) {
        opener_.request(*rewritten, key);
      }

      return true;
    }

    if (!vacant) {
      openingFailed(u"Could not open link: this window already forwards as many ports as it keeps"_s);
      return true;
    }

    startForward(*vacant, target, link->port(), destination);
    return true;
  }

  void LinksController::startForward(std::size_t slot, const application::terminal::links::LinkTarget& target, std::uint16_t port, std::string_view destination) {
    const auto program = system::runtime_endpoint::gatewayProgram();

    forwards_.atMut(slot) = std::make_unique<Forward>();
    auto* forward = forwards_.atMut(slot).get();

    forward->destination = QByteArray{destination.data(), static_cast<qsizetype>(destination.size())};
    forward->remote = port;
    forward->pending = target;
    forward->source = store_.client(store_.machines().active()).key;
    forward->process.setProcessChannelMode(QProcess::SeparateChannels);
    forward->process.setStandardInputFile(QProcess::nullDevice());
    connect(&forward->process, &QProcess::readyReadStandardOutput, this, [this, forward] {
      forwardAnswered(*forward);
    });

    connect(&forward->process, &QProcess::readyReadStandardError, this, [forward] {
      constexpr qsizetype error_limit = 512;

      forward->errors.append(forward->process.readAllStandardError());
      forward->errors.truncate(error_limit);
    });

    connect(&forward->process, &QProcess::finished, this, [this, forward] {
      forwardEnded(forward);
    });

    connect(&forward->process, &QProcess::errorOccurred, this, [this, forward](QProcess::ProcessError error) {
      if (error == QProcess::FailedToStart) {
        forwardEnded(forward);
      }
    });

    forward->process.start(
        QString::fromUtf8(program.view().data(), static_cast<qsizetype>(program.view().size())),
        {u"forward"_s, QString::fromUtf8(forward->destination), QString::number(port), u"a link opened in a window"_s},
        QIODevice::ReadOnly
    );
  }

  void LinksController::forwardAnswered(Forward& forward) {
    constexpr qsizetype answer_limit = 64;

    forward.output.append(forward.process.readAllStandardOutput());
    forward.output.truncate(answer_limit);
    const auto end = forward.output.indexOf('\n');
    if (forward.local != 0 || end < 0) {
      return;
    }

    // The gateway program prints the port here on a line of its own once it listens.
    const auto port = runtime::unsignedDecimal<std::uint16_t>(std::string_view{forward.output.constData(), static_cast<std::size_t>(end)});
    if (!port || *port == 0) {
      return;
    }

    forward.local = *port;
    if (const auto pending = forward.pending.take()) {
      const auto link = application::terminal::links::LocalPortLink::parse(*pending);
      const auto rewritten = link ? link->through(forward.local) : ds::none;

      if (rewritten) {
        opener_.request(*rewritten, forward.source);
      }
    }
  }

  void LinksController::forwardEnded(Forward* ended) {
    // A forward that never listened here could not be made: the person is told why. One that
    // did has only seen its port close there, which needs no word.
    if (ended->local == 0 && ended->pending) {
      const auto said = QString::fromUtf8(ended->errors).trimmed();

      ended->pending.reset();
      openingFailed(u"Could not open link: "_s + (said.isEmpty() ? u"the port could not be forwarded from that machine"_s : said));
    }

    // The process is let go once its own signal has returned.
    QTimer::singleShot(std::chrono::milliseconds{0}, this, [this, ended] {
      for (auto& forward : forwards_.viewMut()) {
        if (forward.get() == ended) {
          forward.reset();
        }
      }
    });
  }

  void LinksController::openAt(std::uint64_t pane_id, CellPosition point) {
    const auto* pane = store_.session().findPane(pane_id);
    if (pane == nullptr) {
      return;
    }

    const auto found = application::terminal::links::CellLinks::text(pane->screen, point);
    if (found) {
      static_cast<void>(open(found->target, pane_id));
    }
  }

  void LinksController::linkOpeningFinished(application::machines::MachineClientKey source, ds::Option<LinkOpeningFailure> failure) {
    auto* client = store_.findMut(source);
    if (client == nullptr || !failure) {
      return;
    }

    std::string_view message;

    switch (*failure) {
    case LinkOpeningFailure::launch:
      message = "Could not open link: host opener is unavailable";
      break;
    case LinkOpeningFailure::process:
      message = "Could not open link: host opener failed";
      break;
    case LinkOpeningFailure::timeout:
      message = "Could not open link: host opener timed out";
      break;
    case LinkOpeningFailure::output_limit:
      message = "Could not open link: host opener exceeded its output limit";
      break;
    }

    application::notifications::publish(client->session, {.title = "Telar", .message = message, .link = {}});
    if (source.machine.slot == store_.machines().active()) {
      notificationPublished();
    }
  }

}
