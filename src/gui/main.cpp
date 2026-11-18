#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "platform/window.hpp"
#include "ui/app/application_controller.hpp"
#include "ui/app/local_runtime_endpoint.hpp"
#include "ui/foundation/fonts/bundled_fonts.hpp"
#include <QCommandLineParser>
#include <QFileInfo>
#include <QFont>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QSGRendererInterface>
#include <QTimer>
#include <QtCore/qcommandlineoption.h>
#include <QtCore/qobject.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtypes.h>
#include <QtQuick/qquickwindow.h>
#include <cstdlib>

import std;
import telar.gui.application;
import telar.gui.foundation.system;
import telar.platform.paths;
import telar.base.ds;

namespace {

  void configureParser(QCommandLineParser& parser) {
    parser.setApplicationDescription(QStringLiteral("Telar Qt Quick client"));
    parser.addHelpOption();

    const QCommandLineOption socket_option{QStringLiteral("socket"), QStringLiteral("Connect to an existing runtime socket"), QStringLiteral("path")};
    const QCommandLineOption smoke_option{QStringLiteral("smoke-ms"), QStringLiteral("Exit after the specified test duration"), QStringLiteral("milliseconds")};
    const QCommandLineOption screenshot_option{QStringLiteral("screenshot"), QStringLiteral("Save the window before the smoke test exits"), QStringLiteral("path")};
    const QCommandLineOption config_option{QStringLiteral("config"), QStringLiteral("Load GUI configuration from a Lua file"), QStringLiteral("path")};
    const QCommandLineOption no_config_option{QStringLiteral("no-config"), QStringLiteral("Use default GUI preferences")};
    const QCommandLineOption profile_option{QStringLiteral("profile"), QStringLiteral("Select a configuration profile"), QStringLiteral("name")};
    const QCommandLineOption theme_option{QStringLiteral("theme"), QStringLiteral("Override the configured color theme"), QStringLiteral("name")};
    const QCommandLineOption directory_option{QStringLiteral("cwd"), QStringLiteral("Set the initial pane working directory"), QStringLiteral("path")};
    const QCommandLineOption fresh_option{QStringLiteral("fresh"), QStringLiteral("Open without restoring this window's saved layout")};
    const QCommandLineOption remote_option{QStringLiteral("remote"), QStringLiteral("Show an SSH destination first and run the command there"), QStringLiteral("destination")};
    const QCommandLineOption machine_option{QStringLiteral("machine"), QStringLiteral("Show a saved machine or the local label first"), QStringLiteral("label")};

    parser.addOptions({
        socket_option,
        smoke_option,
        screenshot_option,
        config_option,
        no_config_option,
        profile_option,
        theme_option,
        directory_option,
        fresh_option,
        remote_option,
        machine_option,
    });

    parser.addPositionalArgument(QStringLiteral("command"), QStringLiteral("Command to run in a newly opened pane"), QStringLiteral("[COMMAND [ARGS...]]"));
    parser.setOptionsAfterPositionalArgumentsMode(QCommandLineParser::ParseAsPositionalArguments);
  }

  // A file in Telar's configuration directory, found as the runtime and the CLI find it; empty
  // without that directory.
  QString telarConfigFile(const QString& name) {
    telar::SystemAllocator memory;
    const auto directory = telar::runtime::cli::RuntimePaths<telar::SystemAllocator>::configHome(memory, telar::runtime::process_environment);

    return directory.empty() ? QString{} : QString::fromUtf8(directory.data(), static_cast<qsizetype>(directory.size())) + QLatin1Char('/') + name;
  }

  // The configuration the runtime reads too: --config, else the one it finds itself when it exists.
  QString configurationPath(const QCommandLineParser& parser) {
    if (parser.isSet(QStringLiteral("no-config"))) {
      return {};
    }

    if (auto path = parser.value(QStringLiteral("config")); !path.isEmpty()) {
      return path;
    }

    telar::SystemAllocator memory;
    const auto file = telar::runtime::cli::RuntimePaths<telar::SystemAllocator>::configFile(memory, telar::runtime::process_environment);
    const auto path = QString::fromUtf8(file.data(), static_cast<qsizetype>(file.size()));

    return !path.isEmpty() && QFileInfo::exists(path) ? path : QString{};
  }

  QString machineProfilesPath() {
    return telarConfigFile(QStringLiteral("machines.json"));
  }

  QString trustStorePath() {
    return telarConfigFile(QStringLiteral("trust.json"));
  }

  QString runtimeEndpoint(const QCommandLineParser& parser, telar::gui::ApplicationAllocator& memory) {
    auto endpoint = parser.value(QStringLiteral("socket"));
    if (endpoint.isEmpty()) {
      endpoint = qEnvironmentVariable("TELAR_SOCKET");
    }

    if (endpoint.isEmpty()) {
      endpoint = telar::gui::qt::LocalRuntimeEndpoint<>::resolve(memory);
    }

    return endpoint;
  }

  telar::ds::Option<QString> initialMachine(const QCommandLineParser& parser, telar::gui::ApplicationAllocator& memory) {
    const auto remote = parser.isSet(QStringLiteral("remote"));
    const auto saved = parser.isSet(QStringLiteral("machine"));
    if (remote && saved) {
      throw std::runtime_error{"--remote and --machine cannot be combined"};
    }

    if (remote && parser.isSet(QStringLiteral("fresh"))) {
      throw std::runtime_error{"--fresh and --remote cannot be combined"};
    }

    for (const auto& name : {QStringLiteral("remote"), QStringLiteral("machine")}) {
      if (parser.values(name).size() > 1 || (parser.isSet(name) && parser.value(name).isEmpty())) {
        throw std::runtime_error{"Machine selection requires one non-empty value"};
      }
    }

    if (remote) {
      return parser.value(QStringLiteral("remote"));
    }

    if (!saved) {
      return telar::ds::none;
    }

    const auto path = machineProfilesPath().toUtf8();
    const telar::gui::system::ProfileFile file{{path.constData(), static_cast<std::size_t>(path.size())}};
    const auto source = file.read(memory);
    const auto profiles = source ? telar::gui::application::machines::MachineProfileCodec::parse(memory, telar::textView(*source)) : telar::gui::application::machines::MachineProfiles{};
    const auto label = parser.value(QStringLiteral("machine")).toUtf8();
    const auto hostname = telar::gui::system::hostName();
    const auto destination = telar::gui::application::machines::MachineOpening::saved(
        profiles,
        {
            label.constData(),
            static_cast<std::size_t>(label.size()),
        },
        {
            hostname.constData(),
            static_cast<std::size_t>(hostname.size()),
        }
    );

    return destination ? telar::ds::Option{QString::fromUtf8(destination->data(), static_cast<qsizetype>(destination->size()))} : telar::ds::none;
  }

  void scheduleSmokeTest(const QCommandLineParser& parser, telar::gui::qt::ApplicationController& client, QQuickWindow& window) {
    if (!parser.isSet(QStringLiteral("smoke-ms"))) {
      return;
    }

    bool valid = false;
    const auto duration = parser.value(QStringLiteral("smoke-ms")).toInt(&valid);
    if (!valid || duration <= 0) {
      throw std::runtime_error{"--smoke-ms requires a positive duration"};
    }

    const auto screenshot_path = parser.value(QStringLiteral("screenshot"));
    const auto capture_screenshot = parser.isSet(QStringLiteral("screenshot"));

    QTimer::singleShot(duration, &client, [&client, &window, screenshot_path, capture_screenshot] {
      if (capture_screenshot && !window.grabWindow().save(screenshot_path)) {
        QGuiApplication::exit(EXIT_FAILURE);

        return;
      }

      std::cout << "connected=" << client.status()->connected() << " panes=" << client.panes()->rows()->rowCount() << " graphics_api=" << static_cast<int>(window.rendererInterface()->graphicsApi()) << " background_opacity=" << client.configuration().background_opacity << " clear_alpha=" << window.color().alphaF() << " alpha_buffer_bits=" << window.format().alphaBufferSize() << " error=" << client.status()->error().toStdString() << '\n';
      const auto healthy = client.status()->connected() && client.panes()->rows()->rowCount() > 0 && client.status()->error().isEmpty();

      QGuiApplication::exit(healthy ? EXIT_SUCCESS : EXIT_FAILURE);
    });
  }

}

int main(int argc, char** argv) {
  QGuiApplication::setApplicationName(QStringLiteral("telar-gui"));
  QGuiApplication::setOrganizationName(QStringLiteral("Telar"));
  telar::gui::platform::configureKeyRepeat();
  const QGuiApplication application{argc, argv};

  telar::gui::platform::configureGraphics();
  QQuickStyle::setStyle(QStringLiteral("Basic"));
  // Wayland compositors find the icon and name through share/applications/telar.desktop.
  QGuiApplication::setDesktopFileName(QStringLiteral("telar"));

  QCommandLineParser parser;

  configureParser(parser);
  parser.process(application);

  try {
    telar::gui::qt::bundledFonts();
    QFont chrome_font{QStringLiteral("IBM Plex Sans")};
    constexpr int chrome_font_pixels = 13;

    chrome_font.setPixelSize(chrome_font_pixels);
    QGuiApplication::setFont(chrome_font);
    telar::gui::ApplicationMemory application_memory;
    telar::gui::ApplicationAllocator& memory = application_memory.memory();
    const auto remote = initialMachine(parser, memory);
    telar::gui::qt::ApplicationController client{memory};

    QObject::connect(client.roster(), &telar::gui::qt::MachineRoster::launchFailed, &application, [](const QString& error) {
      std::cerr << "telar-gui: " << error.toStdString() << '\n';
      QGuiApplication::exit(EXIT_FAILURE);
    });

    client.roster()->configureLaunch(parser.value(QStringLiteral("cwd")), remote ? QStringList{} : parser.positionalArguments(), !parser.isSet(QStringLiteral("fresh")));
    if (remote) {
      client.roster()->configureRemoteLaunch(*remote, parser.positionalArguments());
    }

    client.loadConfiguration(configurationPath(parser), parser.value(QStringLiteral("profile")), parser.value(QStringLiteral("theme")), trustStorePath());
    QQmlApplicationEngine engine;

    engine.rootContext()->setContextProperty(QStringLiteral("telar"), &client);
    engine.loadFromModule(QStringLiteral("Telar.Gui"), QStringLiteral("Main"));

    if (engine.rootObjects().isEmpty()) {
      return EXIT_FAILURE;
    }

    auto* window = qobject_cast<QQuickWindow*>(engine.rootObjects().first());
    if (window == nullptr) {
      return EXIT_FAILURE;
    }

    client.setWindow(*window);
    client.machines()->open(runtimeEndpoint(parser, memory));
    client.roster()->openProfiles(machineProfilesPath());
    scheduleSmokeTest(parser, client, *window);

    return QGuiApplication::exec();
  } catch (const telar::gui::application::machines::MachineFailure& error) {
    const auto* message = error.code() == telar::gui::application::machines::MachineError::unknown_machine ? "no saved machine or local label has that name; see telar machine list" : error.what();

    std::cerr << "telar-gui: " << message << '\n';

    return EXIT_FAILURE;
  } catch (const std::exception& error) {
    std::cerr << "telar-gui: " << error.what() << '\n';

    return EXIT_FAILURE;
  }
}
