#include "application/dependencies.hpp"
#include "config/action_descriptions.hpp"
#include "config/plugin_effects.hpp"
#include "config/plugin_invocation.hpp"
#include "qt/plugin_packages.hpp"
#include "qt/plugin_worker.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/write_descriptor.hpp"
#include "telar_plugins/package_inspection.hpp"
#include <QCoreApplication>
#include <QFile>
#include <QIODevice>
#include <QLatin1StringView>
#include <QString>
#include <QStringLiteral>
#include <QTemporaryDir>
#include <QtCore/qobject.h>
#include <QtCore/qscopeguard.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/qtestcase.h>
#include <array>
#include <cerrno>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <system_error>
#include <unistd.h>
#include <variant>
#include <vector>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;

constexpr std::string_view secret_name = "TELAR_GUI_PLUGIN_TEST_SECRET";
constexpr std::size_t worker_argument_count = 9;

int child(std::span<char *> arguments, const char *const *environment) {
  if (arguments.size() != worker_argument_count) {
    return EXIT_FAILURE;
  }

  const std::string_view action{arguments[3]};
  if (action == "timeout") {
    for (;;) {
      static_cast<void>(::pause());
    }
  }

  if (action == "failure") {
    return EXIT_FAILURE;
  }

  if (action == "environment") {
    for (const auto *entry = environment; *entry != nullptr; ++entry) {
      if (std::string_view{*entry}.starts_with(secret_name)) {
        return EXIT_FAILURE;
      }
    }

    int descriptor = -1;
    const std::string_view descriptor_text{arguments[5]};
    const auto parsed = std::from_chars(descriptor_text.data(), descriptor_text.data() + descriptor_text.size(), descriptor);
    std::uint64_t inode = 0;
    const std::string_view inode_text{arguments[8]};
    const auto parsed_inode = std::from_chars(inode_text.data(), inode_text.data() + inode_text.size(), inode);
    struct stat metadata{};
    if (parsed.ec != std::errc{} || parsed_inode.ec != std::errc{} || descriptor < 0 || std::filesystem::current_path() != "/") {
      return EXIT_FAILURE;
    }

    if (::fstat(descriptor, &metadata) == 0 && static_cast<std::uint64_t>(metadata.st_ino) == inode) {
      return EXIT_FAILURE;
    }
  }

  std::array<telar::Byte, PluginEffects::maximum_bytes + 1> storage{};
  if (action == "overflow") {
    return telar::runtime::writeDescriptor(STDOUT_FILENO, storage) == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
  }

  std::span<telar::Byte> output{storage};
  telar::u8::encode(1, output);
  if (action == "snapshot") {
    constexpr telar::Byte notification_tag = 18;
    telar::u8::encode(notification_tag, output);
    telar::EnumByte<telar::NotificationLevel, 3>::encode(telar::NotificationLevel::info, output);
    telar::u32::encode(telar::default_notification_duration_ms, output);
    const telar::NotificationTarget target;
    telar::ValueCodec<telar::NotificationTarget>::encode(target, output);
    telar::DisplayText16<telar::max_notification_title_bytes, false>::encode(arguments[2], output);
    telar::DisplayText16<telar::max_notification_message_bytes>::encode({}, output);
  } else {
    constexpr telar::Byte toggle_sidebar_tag = 3;
    telar::u8::encode(action == "malformed" ? 0 : toggle_sidebar_tag, output);
  }

  return telar::runtime::writeDescriptor(STDOUT_FILENO, std::span{storage}.first(storage.size() - output.size())) == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

void write(const QString &path, std::string_view bytes) {
  QFile file{path};
  if (!file.open(QIODevice::WriteOnly) || file.write(bytes.data(), static_cast<qint64>(bytes.size())) != static_cast<qint64>(bytes.size())) {
    throw std::runtime_error{"Cannot write plugin worker fixture"};
  }
}

struct Fixture {
  explicit Fixture(ApplicationAllocator &memory) {
    if (!directory.isValid()) {
      throw std::runtime_error{"Cannot create plugin worker fixture"};
    }

    write(directory.filePath(QStringLiteral("plugin.json")), R"({"api_version":1,"id":"fixture","version":"1","entry":"main.lua","source":{"url":"fixture","revision":"1"},"actions":["toggle","snapshot","environment","timeout","overflow","malformed","failure"],"capabilities":[]})");
    write(directory.filePath(QStringLiteral("main.lua")), "return {}");
    const auto path = directory.path().toUtf8();
    invocation.package = telar::runtime::plugins::PackageInspection<PluginPackageHash>::inspect(memory, {path.constData(), static_cast<std::size_t>(path.size())});
    invocation.action.assign("toggle");
  }

  QTemporaryDir directory;
  PluginInvocation invocation;
};

struct Observer {
  std::vector<PluginWorkerResult> results;
  std::vector<std::uint64_t> executions;

  void pluginWorkerFinished(std::uint64_t execution, [[maybe_unused]] const PluginInvocation &invocation, const PluginWorkerResult &result) {
    executions.push_back(execution);
    results.push_back(result);
  }

  [[nodiscard]] bool waitFor(std::size_t count) const {
    return QTest::qWaitFor([&] {
      return results.size() == count;
    });
  }
};

class PluginWorkerTest final : public QObject {
  Q_OBJECT

  Q_SLOT static void successRetainsBusyRunAndReleasesSnapshot() {
    ApplicationAllocator memory;
    Fixture fixture{memory};
    fixture.invocation.action.assign("snapshot");
    Observer observer;
    PluginWorker worker{memory, observer};
    const auto program = QCoreApplication::applicationFilePath();
    worker.start(fixture.invocation, 1, program);
    QVERIFY(worker.active());
    QVERIFY_THROWS_EXCEPTION(std::runtime_error, worker.start(fixture.invocation, 2, program));
    QVERIFY(observer.waitFor(1));
    QVERIFY(!worker.active());
    QCOMPARE(observer.executions.front(), std::uint64_t{1});
    QCOMPARE(observer.results.front().error, QString{});
    const auto &result = observer.results.front();
    if (!result.effects) {
      QFAIL("Worker did not return effects");
    }

    const auto *notification = std::get_if<NotificationActionDescription>(&result.effects->effects().front());
    if (notification == nullptr) {
      QFAIL("Worker did not return the snapshot notification");
    }

    const auto entry = QString::fromUtf8(notification->title.view().data(), static_cast<qsizetype>(notification->title.view().size()));
    QVERIFY(entry.startsWith(QLatin1StringView{"/tmp/telar-gui-plugin-worker-"}));
    QVERIFY(!QFile::exists(entry));
    QVERIFY(QFile::exists(fixture.directory.filePath(QStringLiteral("main.lua"))));
  }

  Q_SLOT static void environmentDirectoryAndDescriptorsAreIsolated() {
    ApplicationAllocator memory;
    Fixture fixture{memory};
    const auto name = std::string{secret_name};
    const auto previous = qgetenv(name.c_str());
    const auto restore = qScopeGuard([&] {
      if (previous.isNull()) {
        static_cast<void>(qunsetenv(name.c_str()));
      } else {
        static_cast<void>(qputenv(name.c_str(), previous));
      }
    });
    QVERIFY(qputenv(name.c_str(), "test-only"));
    const auto path = fixture.directory.filePath(QStringLiteral("inherited-file"));
    write(path, "must remain in parent");
    QFile file{path};
    QVERIFY(file.open(QIODevice::ReadOnly));
    const int source = file.handle();
    if (source < 0) {
      QFAIL("Cannot access inherited descriptor fixture");
    }

    const telar::runtime::FileDescriptor descriptor{::dup(source)};
    const int inherited = descriptor.get();
    if (inherited < 0) {
      QFAIL("Cannot duplicate inherited descriptor fixture");
    }

    struct stat metadata{};
    QCOMPARE(::fstat(inherited, &metadata), 0);
    fixture.invocation.context.tab_count = static_cast<std::uint16_t>(inherited);
    fixture.invocation.context.focused_pane_id = static_cast<std::uint64_t>(metadata.st_ino);
    fixture.invocation.action.assign("environment");
    // Refresh the expected package after adding the descriptor fixture.
    const auto root = fixture.directory.path().toUtf8();
    fixture.invocation.package = telar::runtime::plugins::PackageInspection<PluginPackageHash>::inspect(memory, {root.constData(), static_cast<std::size_t>(root.size())});
    Observer observer;
    PluginWorker worker{memory, observer};
    worker.start(fixture.invocation, 1, QCoreApplication::applicationFilePath());
    QVERIFY(observer.waitFor(1));
    QCOMPARE(observer.results.front().error, QString{});
    QVERIFY(observer.results.front().effects);
  }

  Q_SLOT static void failuresAreBoundedAndPermitReuse() {
    ApplicationAllocator memory;
    Fixture fixture{memory};
    Observer observer;
    PluginWorker worker{memory, observer};

    struct Case {
      const char *action;
      const char *error;
    };

    constexpr std::array cases{Case{.action = "overflow", .error = "PluginWorkerFailed"}, Case{.action = "malformed", .error = "UnknownWorkerEffect"}, Case{.action = "failure", .error = "PluginWorkerFailed"}, Case{.action = "timeout", .error = "PluginWorkerTimedOut"}};
    std::size_t completed = 0;
    for (const auto &entry : cases) {
      fixture.invocation.action.assign(entry.action);
      worker.start(fixture.invocation, ++completed, QCoreApplication::applicationFilePath());
      QVERIFY(observer.waitFor(completed));
      QCOMPARE(observer.results.back().error, QString::fromUtf8(entry.error));
      QVERIFY(!observer.results.back().effects);
      QVERIFY(!worker.active());
    }
  }

  Q_SLOT static void changedPackageNeverStartsWorker() {
    ApplicationAllocator memory;
    const Fixture fixture{memory};
    write(fixture.directory.filePath(QStringLiteral("main.lua")), "return {changed=true}");
    Observer observer;
    PluginWorker worker{memory, observer};
    worker.start(fixture.invocation, 1, QCoreApplication::applicationFilePath());
    QVERIFY(observer.waitFor(1));
    QVERIFY(!observer.results.front().error.isEmpty());
    QVERIFY(!observer.results.front().effects);
    QVERIFY(!worker.active());
  }
};

}

int main(int argc, char **argv, char *const *environment) {
  try {
    if (argc > 1 && std::string_view{argv[1]} == "plugin-worker") {
      return child({argv, static_cast<std::size_t>(argc)}, environment);
    }

    const QCoreApplication application{argc, argv};
    PluginWorkerTest test;

    return QTest::qExec(&test, argc, argv);
  } catch (const std::exception &) {
    return EXIT_FAILURE;
  }
}

#include "plugin_worker_test.moc"
