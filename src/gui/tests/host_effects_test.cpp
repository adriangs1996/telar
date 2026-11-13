#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include "../core/memory.hpp"
#include <algorithm>
#include <span>
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstdint>
#include "../qt/command_process.hpp"
#include "../qt/sound_player.hpp"
#include "../qt/system_notifier.hpp"
#include <QCoreApplication>
#include <QIODevice>
#include <QObject>
#include <QProcess>
#include <QString>
#include <QStringLiteral>
#include <QStringList>
#include <QtCore/qtmetamacros.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <chrono>
#include <functional>
#include <memory>
#include <new>
#include <optional>
#include <vector>

#include "core/memory.hpp"
#include "qt/command_process.hpp"
#include "qt/sound_player.hpp"
#include "qt/system_notifier.hpp"

import telar.gui.tests.allocation_gate;
import telar.gui.application.host_effects;
import telar.gui.platform.notification_commands;

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;
using telar::AgentSound;

constexpr int wait_ms = 5000;

enum class FailureMode : std::uint8_t {
  process,
  launch,
  timeout,
  output,
};

struct SoundHost {
  static constexpr auto timeout = std::chrono::milliseconds{100};
  static constexpr auto attempts = platform::LinuxSoundCommands::attempts;
  inline static std::vector<platform::SoundAttempt> started;
  inline static std::size_t successful_backend = 0;
  inline static FailureMode failure = FailureMode::process;

  static void start(QProcess &process, platform::SoundAttempt request) {
    started.push_back(request);
    if (request.backend >= successful_backend) {
      process.start(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), QStringLiteral("exit 0")}, QIODevice::ReadOnly);

      return;
    }

    switch (failure) {
    case FailureMode::launch:
      process.start(QStringLiteral("/"));
      break;
    case FailureMode::timeout:
      process.start(QStringLiteral("/bin/sleep"), {QStringLiteral("60")});
      break;
    case FailureMode::output:
      process.start(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), QStringLiteral("dd if=/dev/zero bs=4097 count=1 2>/dev/null")}, QIODevice::ReadOnly);
      break;
    case FailureMode::process:
      process.start(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), QStringLiteral("exit 1")}, QIODevice::ReadOnly);
      break;
    }
  }
};

struct Observer {
  std::vector<std::optional<CommandFailure>> results;
  std::function<void()> completed;

  void soundPlaybackFinished(std::optional<CommandFailure> failure) {
    results.push_back(failure);
    if (completed) {
      completed();
    }
  }
};

struct NotificationHost {
  static constexpr auto timeout = SoundHost::timeout;
  inline static std::vector<NotificationPayload> started;
  inline static FailureMode failure = FailureMode::process;
  inline static bool succeeds = true;

  static void start(QProcess &process, const NotificationPayload &payload) {
    started.push_back(payload);
    if (!succeeds && failure == FailureMode::launch) {
      process.start(QStringLiteral("/"));
    } else if (!succeeds && failure == FailureMode::timeout) {
      process.start(QStringLiteral("/bin/sleep"), {QStringLiteral("60")});
    } else {
      process.start(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), succeeds ? QStringLiteral("exit 0") : QStringLiteral("exit 1")}, QIODevice::ReadOnly);
    }
  }
};

class HostEffectsTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void init() {
    SoundHost::started.clear();
    SoundHost::successful_backend = 0;
    SoundHost::failure = FailureMode::process;
    NotificationHost::started.clear();
    NotificationHost::succeeds = true;
    NotificationHost::failure = FailureMode::process;
  }

  Q_SLOT static void successfulAudioStopsAtTheFirstAvailableBackend() {
    Observer observer;
    SoundPlayer<SoundHost, Observer> player{observer};
    player.start(AgentSound::ready);
    QTRY_COMPARE_WITH_TIMEOUT(observer.results.size(), std::size_t{1}, wait_ms);
    QCOMPARE(SoundHost::started.size(), std::size_t{1});
    QVERIFY(!observer.results.front());
    QVERIFY(!player.active());
  }

  Q_SLOT static void failedBackendsRetainTheSemanticSoundAndStopAfterSuccess() {
    constexpr std::size_t successful_backend = 2;
    SoundHost::successful_backend = successful_backend;
    Observer observer;
    SoundPlayer<SoundHost, Observer> player{observer};
    player.start(AgentSound::needs_input);
    QTRY_COMPARE_WITH_TIMEOUT(observer.results.size(), std::size_t{1}, wait_ms);
    QCOMPARE(SoundHost::started.size(), successful_backend + 1);
    QVERIFY(!observer.results.front());
    for (std::size_t index = 0; index < SoundHost::started.size(); ++index) {
      QCOMPARE(SoundHost::started[index].backend, index);
      QCOMPARE(SoundHost::started[index].sound, AgentSound::needs_input);
    }
  }

  Q_SLOT static void exhaustingAllBackendsCompletesOnceAndPermitsTheNextSound() {
    SoundHost::successful_backend = SoundHost::attempts;
    Observer observer;
    SoundPlayer<SoundHost, Observer> player{observer};
    player.start(AgentSound::ready);
    QTRY_COMPARE_WITH_TIMEOUT(observer.results.size(), std::size_t{1}, wait_ms);
    QCOMPARE(SoundHost::started.size(), SoundHost::attempts);
    QCOMPARE(observer.results.front(), std::optional{CommandFailure::process});

    SoundHost::successful_backend = 0;
    player.start(AgentSound::needs_input);
    QTRY_COMPARE_WITH_TIMEOUT(observer.results.size(), std::size_t{2}, wait_ms);
    QCOMPARE(SoundHost::started.back().backend, std::size_t{0});
    QVERIFY(!observer.results.back());
  }

  Q_SLOT static void launchTimeoutAndOutputFailuresAlsoFallBack() {
    for (const auto failure : {FailureMode::launch, FailureMode::timeout, FailureMode::output}) {
      SoundHost::started.clear();
      SoundHost::successful_backend = 1;
      SoundHost::failure = failure;
      Observer observer;
      SoundPlayer<SoundHost, Observer> player{observer};
      player.start(AgentSound::ready);
      QTRY_COMPARE_WITH_TIMEOUT(observer.results.size(), std::size_t{1}, wait_ms);
      QCOMPARE(SoundHost::started.size(), std::size_t{2});
      QVERIFY(!observer.results.front());
    }
  }

  Q_SLOT static void aSecondStartCannotReplaceTheActiveAttempt() {
    SoundHost::successful_backend = 1;
    Observer observer;
    SoundPlayer<SoundHost, Observer> player{observer};
    player.start(AgentSound::needs_input);
    QVERIFY_THROWS_EXCEPTION(std::logic_error, player.start(AgentSound::ready));
    QTRY_COMPARE_WITH_TIMEOUT(observer.results.size(), std::size_t{1}, wait_ms);
    QCOMPARE(SoundHost::started.front().sound, AgentSound::needs_input);
    QCOMPARE(SoundHost::started.back().sound, AgentSound::needs_input);
  }

  Q_SLOT static void teardownCancelsDeferredAudioWithoutCallingTheHost() {
    Observer observer;
    {
      SoundPlayer<SoundHost, Observer> player{observer};
      player.start(AgentSound::ready);
    }

    QCoreApplication::processEvents();
    QVERIFY(SoundHost::started.empty());
    QVERIFY(observer.results.empty());
  }

  Q_SLOT static void completionMayDestroyThePlayer() {
    Observer observer;
    auto player = std::make_unique<SoundPlayer<SoundHost, Observer>>(observer);
    observer.completed = [&] {
      player.reset();
    };
    player->start(AgentSound::ready);
    QTRY_VERIFY_WITH_TIMEOUT(!player, wait_ms);
    QCOMPARE(observer.results.size(), std::size_t{1});
  }

  Q_SLOT static void noticesOwnDeferredPayloadAndReuseCompletedCapacity() {
    SystemAllocator memory;
    SystemNotifier<NotificationHost, SystemAllocator> notifier{memory};
    auto payload = NotificationPayload::create("Original", "Owned message");
    QVERIFY(notifier.post(payload));
    payload.title.assign("Modified");
    QTRY_COMPARE_WITH_TIMEOUT(NotificationHost::started.size(), std::size_t{1}, wait_ms);
    QCOMPARE(NotificationHost::started.front().title.view(), std::string_view{"Original"});
    QTRY_COMPARE_WITH_TIMEOUT(notifier.activeCount(), std::size_t{0}, wait_ms);
    QVERIFY(notifier.post(payload));
    QTRY_COMPARE_WITH_TIMEOUT(notifier.activeCount(), std::size_t{0}, wait_ms);
    QCOMPARE(NotificationHost::started.back().title.view(), std::string_view{"Modified"});
  }

  Q_SLOT static void desktopSaturationDropsNewWorkWithoutReplacingRetainedNotices() {
    constexpr std::size_t capacity = 4;
    SystemAllocator memory;
    SystemNotifier<NotificationHost, SystemAllocator, capacity> notifier{memory};
    const auto payload = NotificationPayload::create("Retained", "message");
    for (std::size_t index = 0; index < capacity; ++index) {
      QVERIFY(notifier.post(payload));
    }

    QVERIFY(!notifier.post(NotificationPayload::create("Dropped", "message")));
    QCOMPARE(notifier.activeCount(), capacity);
    QTRY_COMPARE_WITH_TIMEOUT(notifier.activeCount(), std::size_t{0}, wait_ms);
    QCOMPARE(NotificationHost::started.size(), capacity);
    for (const auto &notice : NotificationHost::started) {
      QCOMPARE(notice.title.view(), std::string_view{"Retained"});
    }
  }

  Q_SLOT static void desktopFailuresAreNotRetriedAndReleaseTheirSlot() {
    for (const auto failure : {FailureMode::launch, FailureMode::timeout, FailureMode::process}) {
      NotificationHost::started.clear();
      NotificationHost::succeeds = false;
      NotificationHost::failure = failure;
      SystemAllocator memory;
      SystemNotifier<NotificationHost, SystemAllocator> notifier{memory};
      QVERIFY(notifier.post(NotificationPayload::create("Unavailable", "message")));
      QTRY_COMPARE_WITH_TIMEOUT(notifier.activeCount(), std::size_t{0}, wait_ms);
      QCOMPARE(NotificationHost::started.size(), std::size_t{1});
    }
  }

  Q_SLOT static void desktopAdmissionUsesTheInjectedAllocatorAndReusesItsStorage() {
    SystemAllocator memory;
    test::AllocationGate<SystemAllocator> gated{memory};
    SystemNotifier<NotificationHost, decltype(gated)> notifier{gated};
    const auto payload = NotificationPayload::create("Allocation test", "message");
    gated.permit(0);
    QVERIFY_THROWS_EXCEPTION(std::bad_alloc, static_cast<void>(notifier.post(payload)));
    QCOMPARE(notifier.activeCount(), std::size_t{0});

    gated.permit(1);
    QVERIFY(notifier.post(payload));
    QTRY_COMPARE_WITH_TIMEOUT(notifier.activeCount(), std::size_t{0}, wait_ms);
    gated.permit(0);
    QVERIFY(notifier.post(payload));
    QTRY_COMPARE_WITH_TIMEOUT(notifier.activeCount(), std::size_t{0}, wait_ms);
    QCOMPARE(NotificationHost::started.size(), std::size_t{2});
  }
};

}

int main(int argc, char **argv) {
  const QCoreApplication application{argc, argv};
  HostEffectsTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "host_effects_test.moc"
