#include "application/dependencies.hpp"
#include "assertions.hpp"
#include "machines/edit.hpp"
#include "machines/messages.hpp"
#include "machines/profile.hpp"
#include "platform/profile_file.hpp"
#include "qt/machine_profiles_source.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <QElapsedTimer>
#include <QObject>
#include <QSignalSpy>
#include <QString>
#include <QTemporaryDir>
#include <QtCore/qstring.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <cstddef>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

namespace {

using namespace telar::gui;
using telar::gui::qt::MachineProfilesSource;
constexpr int wait_ms = 5000;

platform::ProfileFile profileFile(const QString &path) {
  const auto encoded = path.toUtf8();

  return platform::ProfileFile{{encoded.constData(), static_cast<std::size_t>(encoded.size())}};
}

void replaceFile(const QString &path, std::string_view source) {
  const auto file = profileFile(path);
  const auto transaction = file.lock();
  transaction.replace(source);
}

QString fromText(std::string_view text) {
  return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
}

class MachineProfilesSourceTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void loadsMissingProfilesAndPollsExternalReplacements() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("machines.json"));
    ApplicationAllocator memory;
    MachineProfilesSource source{memory};
    source.open(path, QStringLiteral("local"));
    QTRY_VERIFY_WITH_TIMEOUT(source.loaded(), wait_ms);
    QVERIFY(source.error().isEmpty());
    QVERIFY(source.profiles().rows().empty());
    const auto initial_revision = source.revision();
    replaceFile(path, R"({"version":1,"local_label":"alias","machines":[{"id":"m-000000000001","label":"build","destination":"dev@build","enabled":true}]})");
    source.poll();
    QTRY_VERIFY_WITH_TIMEOUT(source.revision() > initial_revision, wait_ms);
    QCOMPARE(source.profiles().rows().size(), std::size_t{1});
    QCOMPARE(fromText(source.profiles().rows().front().label()), QStringLiteral("build"));
    const auto local_label = test::requireValue(source.profiles().localLabel(), "the file's local alias must be present after loading");
    QCOMPARE(fromText(local_label), QStringLiteral("alias"));
    const auto unchanged_revision = source.revision();
    source.poll();
    QTRY_VERIFY_WITH_TIMEOUT(!source.busy(), wait_ms);
    QCOMPARE(source.revision(), unchanged_revision);
  }

  Q_SLOT static void copiesPendingEditsAndRefusesAnotherConcurrentEdit() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("machines.json"));
    ApplicationAllocator memory;
    MachineProfilesSource source{memory};
    source.open(path, QStringLiteral("local"));
    QTRY_VERIFY_WITH_TIMEOUT(source.loaded(), wait_ms);
    const auto file = profileFile(path);
    std::optional<platform::ProfileFileTransaction> held{file.lock()};
    std::string label = "build";
    std::string destination = "dev@build";
    std::string color = "#a0B1c2";
    QVERIFY(source.edit({.kind = MachineEditKind::add, .label = label, .value = destination, .color = color, .enabled = false}));
    QVERIFY(source.editing());
    label.assign(label.size(), 'x');
    destination.assign(destination.size(), 'y');
    color.assign(color.size(), 'z');
    QSignalSpy failures{&source, &MachineProfilesSource::failed};
    QVERIFY(!source.edit({.kind = MachineEditKind::add, .label = "second", .value = "dev@second"}));
    QCOMPARE(failures.count(), 1);
    QVERIFY(failures.takeFirst().isEmpty());
    QCOMPARE(source.error(), fromText(MachineProfileMessages::edit_pending));
    held.reset();
    QTRY_VERIFY_WITH_TIMEOUT(!source.editing(), wait_ms);
    QCOMPARE(source.profiles().rows().size(), std::size_t{1});
    const auto &profile = source.profiles().rows().front();
    QCOMPARE(fromText(profile.label()), QStringLiteral("build"));
    QCOMPARE(fromText(profile.destination()), QStringLiteral("dev@build"));
    QCOMPARE(fromText(profile.color().value_or("missing")), QStringLiteral("#a0B1c2"));
    QVERIFY(!profile.enabled());
    QVERIFY(source.loaded());
    QVERIFY(profile.identity().value() != 0);
    QVERIFY(source.error().isEmpty());
  }

  Q_SLOT static void recoversAfterAnUnreadableFileAndRetainsTheLastValidProfiles() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("machines.json"));
    replaceFile(path, R"({"version":1,"machines":[{"id":"m-000000000001","label":"build","destination":"dev@build"}]})");
    ApplicationAllocator memory;
    MachineProfilesSource source{memory};
    source.open(path, QStringLiteral("local"));
    QTRY_VERIFY_WITH_TIMEOUT(source.loaded(), wait_ms);
    QCOMPARE(source.profiles().rows().size(), std::size_t{1});
    QSignalSpy failures{&source, &MachineProfilesSource::failed};
    replaceFile(path, "invalid profile JSON");
    source.poll();
    QVERIFY(failures.wait(wait_ms));
    QCOMPARE(failures.count(), 1);
    QCOMPARE(source.profiles().rows().size(), std::size_t{1});
    QVERIFY(!source.error().isEmpty());
    const auto previous = source.revision();
    replaceFile(path, "{\"version\":1,\"machines\":[]}\n");
    source.poll();
    QTRY_VERIFY_WITH_TIMEOUT(source.revision() > previous, wait_ms);
    QVERIFY(source.profiles().rows().empty());
    QVERIFY(source.error().isEmpty());
  }

  Q_SLOT static void savingForcesAReadEvenWhenAnotherWriterRestoresTheOldStamp() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("machines.json"));
    const auto native_path = std::filesystem::path{path.toStdString()};
    ApplicationAllocator memory;
    MachineProfilesSource source{memory};
    source.open(path, QStringLiteral("local"));
    QTRY_VERIFY_WITH_TIMEOUT(source.loaded(), wait_ms);
    QVERIFY(source.edit({.kind = MachineEditKind::add, .label = "build", .value = "dev@build"}));
    QTRY_VERIFY_WITH_TIMEOUT(!source.editing(), wait_ms);
    QCOMPARE(source.profiles().rows().size(), std::size_t{1});
    source.poll();
    QTRY_VERIFY_WITH_TIMEOUT(!source.busy(), wait_ms);
    const auto original_time = std::filesystem::last_write_time(native_path);
    const auto original_size = std::filesystem::file_size(native_path);
    bool overwritten = false;
    connect(&source, &MachineProfilesSource::changed, &source, [&] {
      if (!overwritten && !source.profiles().rows().empty() && source.profiles().rows().front().label() == "other") {
        const auto file = profileFile(path);
        const auto bytes = test::requireValue(file.read(memory), "the committed profile file must remain readable");
        std::string replacement{telar::textView(bytes)};
        const auto position = replacement.find("other");
        test::require(position != std::string::npos, "the renamed machine must be present in the committed JSON");
        replacement.replace(position, std::string_view{"other"}.size(), "third");
        replaceFile(path, replacement);
        std::filesystem::last_write_time(native_path, original_time);
        overwritten = true;
      }
    });
    QVERIFY(source.edit({.kind = MachineEditKind::rename, .label = "build", .value = "other"}));
    QTRY_VERIFY_WITH_TIMEOUT(!source.editing(), wait_ms);
    QVERIFY(overwritten);
    QCOMPARE(std::filesystem::file_size(native_path), original_size);
    QCOMPARE(std::filesystem::last_write_time(native_path), original_time);
    source.poll();
    QTRY_VERIFY_WITH_TIMEOUT(!source.busy(), wait_ms);
    QCOMPARE(fromText(source.profiles().rows().front().label()), QStringLiteral("third"));
  }

  Q_SLOT static void shutdownCancelsAnEditWaitingForAnotherWriter() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("machines.json"));
    ApplicationAllocator memory;
    auto source = std::make_unique<MachineProfilesSource>(memory);
    source->open(path, QStringLiteral("local"));
    QTRY_VERIFY_WITH_TIMEOUT(source->loaded(), wait_ms);
    const auto file = profileFile(path);
    const auto held = file.lock();
    QVERIFY(source->edit({.kind = MachineEditKind::add, .label = "build", .value = "dev@build"}));
    QElapsedTimer elapsed;
    elapsed.start();
    source.reset();
    constexpr qint64 shutdown_limit_ms = 1000;
    QVERIFY(elapsed.elapsed() < shutdown_limit_ms);
    QVERIFY(!file.read(memory).has_value());
  }

  Q_SLOT static void reopeningIgnoresThePreviousWorkerAndSupportsReentrantChanges() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto first = directory.filePath(QStringLiteral("first.json"));
    const auto second = directory.filePath(QStringLiteral("second.json"));
    replaceFile(first, R"({"version":1,"machines":[{"id":"m-000000000001","label":"first","destination":"dev@first"}]})");
    replaceFile(second, R"({"version":1,"machines":[{"id":"m-000000000002","label":"second","destination":"dev@second"}]})");
    ApplicationAllocator memory;
    MachineProfilesSource source{memory};
    bool reopened = false;
    connect(&source, &MachineProfilesSource::changed, &source, [&] {
      if (!reopened && source.loaded() && !source.profiles().rows().empty()) {
        reopened = true;
        source.open(second, QStringLiteral("local"));
      }
    });
    source.open(first, QStringLiteral("local"));
    QTRY_VERIFY_WITH_TIMEOUT(reopened && source.loaded(), wait_ms);
    QCOMPARE(source.profiles().rows().size(), std::size_t{1});
    QCOMPARE(fromText(source.profiles().rows().front().label()), QStringLiteral("second"));
  }
};

}

QTEST_GUILESS_MAIN(MachineProfilesSourceTest)
#include "machine_profiles_source_test.moc"
