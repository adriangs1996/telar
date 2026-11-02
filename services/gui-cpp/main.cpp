#include "application/dependencies.hpp"
#include "machines/opening.hpp"
#include "machines/failure.hpp"
#include "machines/profile_codec.hpp"
#include "machines/profiles.hpp"
#include "platform/host_name.hpp"
#include "platform/profile_file.hpp"
#include "platform/window.hpp"
#include "qt/application.hpp"
#include "qt/local_runtime_endpoint.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "qt/bundled_fonts.hpp"
#include <QCommandLineParser>
#include <QDir>
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
#include <exception>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace {

void configureParser(QCommandLineParser &parser) {
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
  parser.addOptions({socket_option, smoke_option, screenshot_option, config_option, no_config_option, profile_option, theme_option, directory_option, fresh_option, remote_option, machine_option});
  parser.addPositionalArgument(QStringLiteral("command"), QStringLiteral("Command to run in a newly opened pane"), QStringLiteral("[COMMAND [ARGS...]]"));
  parser.setOptionsAfterPositionalArgumentsMode(QCommandLineParser::ParseAsPositionalArguments);
}

QString configurationPath(const QCommandLineParser &parser) {
  if (parser.isSet(QStringLiteral("no-config"))) {
    return {};
  }

  auto path = parser.value(QStringLiteral("config"));
  if (path.isEmpty()) {
    path = qEnvironmentVariable("TELAR_DEVELOPMENT_CONFIG");
  }

  if (!path.isEmpty()) {
    return path;
  }

  const QDir directory{qEnvironmentVariable("XDG_CONFIG_HOME", QDir::homePath() + QStringLiteral("/.config"))};
  path = directory.filePath(QStringLiteral("telar/config.lua"));

  return QFileInfo::exists(path) ? path : QString{};
}

QString machineProfilesPath() {
  const auto base = qEnvironmentVariable("XDG_CONFIG_HOME");
  if (!base.isEmpty()) {
    return base + QStringLiteral("/telar/machines.json");
  }

  const auto home = qEnvironmentVariable("HOME");

  return home.isEmpty() ? QString{} : home + QStringLiteral("/.config/telar/machines.json");
}

QString trustStorePath() {
  const auto base = qEnvironmentVariable("XDG_CONFIG_HOME");
  if (!base.isEmpty()) {
    return base + QStringLiteral("/telar/trust.json");
  }

  const auto home = qEnvironmentVariable("HOME");

  return home.isEmpty() ? QString{} : home + QStringLiteral("/.config/telar/trust.json");
}

QString runtimeEndpoint(const QCommandLineParser &parser, telar::gui::ApplicationAllocator &memory) {
  auto endpoint = parser.value(QStringLiteral("socket"));
  if (endpoint.isEmpty()) {
    endpoint = qEnvironmentVariable("TELAR_SOCKET");
  }

  if (endpoint.isEmpty()) {
    endpoint = telar::gui::qt::LocalRuntimeEndpoint<>::resolve(memory);
  }

  return endpoint;
}

std::optional<QString> initialMachine(const QCommandLineParser &parser, telar::gui::ApplicationAllocator &memory) {
  const auto remote = parser.isSet(QStringLiteral("remote"));
  const auto saved = parser.isSet(QStringLiteral("machine"));
  if (remote && saved) {
    throw std::runtime_error{"--remote and --machine cannot be combined"};
  }

  if (remote && parser.isSet(QStringLiteral("fresh"))) {
    throw std::runtime_error{"--fresh and --remote cannot be combined"};
  }

  for (const auto &name : {QStringLiteral("remote"), QStringLiteral("machine")}) {
    if (parser.values(name).size() > 1 || (parser.isSet(name) && parser.value(name).isEmpty())) {
      throw std::runtime_error{"Machine selection requires one non-empty value"};
    }
  }

  if (remote) {
    return parser.value(QStringLiteral("remote"));
  }

  if (!saved) {
    return std::nullopt;
  }

  const auto path = machineProfilesPath().toUtf8();
  const telar::gui::platform::ProfileFile file{{path.constData(), static_cast<std::size_t>(path.size())}};
  const auto source = file.read(memory);
  const auto profiles = source ? telar::gui::MachineProfileCodec::parse(memory, telar::textView(*source)) : telar::gui::MachineProfiles{};
  const auto label = parser.value(QStringLiteral("machine")).toUtf8();
  const auto hostname = telar::gui::platform::hostName();
  const auto destination = telar::gui::MachineOpening::saved(profiles, {label.constData(), static_cast<std::size_t>(label.size())}, {hostname.constData(), static_cast<std::size_t>(hostname.size())});

  return destination ? std::optional{QString::fromUtf8(destination->data(), static_cast<qsizetype>(destination->size()))} : std::nullopt;
}

void scheduleSmokeTest(const QCommandLineParser &parser, telar::gui::qt::Application &client, QQuickWindow &window) {
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

    std::cout << "connected=" << client.connected() << " panes=" << client.panes()->rowCount() << " graphics_api=" << static_cast<int>(window.rendererInterface()->graphicsApi()) << " error=" << client.error().toStdString() << '\n';
    const auto healthy = client.connected() && client.panes()->rowCount() > 0 && client.error().isEmpty();
    QGuiApplication::exit(healthy ? EXIT_SUCCESS : EXIT_FAILURE);
  });
}

}

int main(int argc, char **argv) {
  QGuiApplication::setApplicationName(QStringLiteral("telar-gui"));
  QGuiApplication::setOrganizationName(QStringLiteral("Telar"));
  telar::gui::platform::configureKeyRepeat();
  const QGuiApplication application{argc, argv};
  telar::gui::platform::configureGraphics();
  QQuickStyle::setStyle(QStringLiteral("Basic"));
  QGuiApplication::setDesktopFileName(QStringLiteral("telar-gui"));

  QCommandLineParser parser;
  configureParser(parser);
  parser.process(application);

  try {
    telar::gui::qt::bundledFonts();
    QFont chrome_font{QStringLiteral("IBM Plex Sans")};
    constexpr int chrome_font_pixels = 13;
    chrome_font.setPixelSize(chrome_font_pixels);
    QGuiApplication::setFont(chrome_font);
    telar::gui::ApplicationAllocator memory;
    const auto remote = initialMachine(parser, memory);
    telar::gui::qt::Application client{memory};
    QObject::connect(&client, &telar::gui::qt::Application::machineLaunchFailed, &application, [](const QString &error) {
      std::cerr << "telar-gui: " << error.toStdString() << '\n';
      QGuiApplication::exit(EXIT_FAILURE);
    });
    client.configureLaunch(parser.value(QStringLiteral("cwd")), remote ? QStringList{} : parser.positionalArguments(), !parser.isSet(QStringLiteral("fresh")));
    if (remote) {
      client.configureRemoteLaunch(*remote, parser.positionalArguments());
    }
    client.loadConfiguration(configurationPath(parser), parser.value(QStringLiteral("profile")), parser.value(QStringLiteral("theme")), trustStorePath());
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("telar"), &client);
    engine.loadFromModule(QStringLiteral("Telar.Gui"), QStringLiteral("Main"));

    if (engine.rootObjects().isEmpty()) {
      return EXIT_FAILURE;
    }

    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    if (window == nullptr) {
      return EXIT_FAILURE;
    }

    client.setWindow(*window);
    client.open(runtimeEndpoint(parser, memory));
    client.openMachines(machineProfilesPath());
    scheduleSmokeTest(parser, client, *window);

    return QGuiApplication::exec();
  } catch (const telar::gui::MachineFailure &error) {
    const auto *message = error.code() == telar::gui::MachineError::unknown_machine ? "no saved machine or local label has that name; see telar machine list" : error.what();
    std::cerr << "telar-gui: " << message << '\n';

    return EXIT_FAILURE;
  } catch (const std::exception &error) {
    std::cerr << "telar-gui: " << error.what() << '\n';

    return EXIT_FAILURE;
  }
}
