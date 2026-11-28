#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include <QCoreApplication>
#include <QIODevice>
#include <QObject>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QtCore/qtmetamacros.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <new>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <vector>

import telar.gui.tests.allocation_gate;
import telar.gui.application;
import telar.gui.foundation.system;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.gui.ui.app.overlays.notifications;
import telar.gui.ui.kit.process;
import telar.gui.tests.qt_case;
import telar.gui.qt;

namespace {
  using Qt::StringLiterals::operator""_s;

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
    static constexpr auto attempts = system::LinuxSoundCommands::attempts;
    inline static std::vector<system::SoundAttempt> started;
    inline static std::size_t successful_backend = 0;
    inline static FailureMode failure = FailureMode::process;

    static void start(QProcess& process, system::SoundAttempt request) {
      started.push_back(request);
      if (request.backend >= successful_backend) {
        process.start(u"/bin/sh"_s, {u"-c"_s, u"exit 0"_s}, QIODevice::ReadOnly);

        return;
      }

      switch (failure) {
      case FailureMode::launch:
        process.start(u"/"_s);
        break;
      case FailureMode::timeout:
        process.start(u"/bin/sleep"_s, {u"60"_s});
        break;
      case FailureMode::output:
        process.start(u"/bin/sh"_s, {u"-c"_s, u"dd if=/dev/zero bs=4097 count=1 2>/dev/null"_s}, QIODevice::ReadOnly);
        break;
      case FailureMode::process:
        process.start(u"/bin/sh"_s, {u"-c"_s, u"exit 1"_s}, QIODevice::ReadOnly);
        break;
      }
    }
  };

  struct Observer {
    std::vector<telar::ds::Option<CommandFailure>> results;
    std::function<void()> completed;

    void soundPlaybackFinished(telar::ds::Option<CommandFailure> failure) {
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

    static void start(QProcess& process, const NotificationPayload& payload) {
      started.push_back(payload);
      if (!succeeds && failure == FailureMode::launch) {
        process.start(u"/"_s);
      } else if (!succeeds && failure == FailureMode::timeout) {
        process.start(u"/bin/sleep"_s, {u"60"_s});
      } else {
        process.start(u"/bin/sh"_s, {u"-c"_s, succeeds ? u"exit 0"_s : u"exit 1"_s}, QIODevice::ReadOnly);
      }
    }
  };

  class [[qt::object]] HostEffectsTest final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

  private:
  private:
    [[qt::slot]] static void init() {
      SoundHost::started.clear();
      SoundHost::successful_backend = 0;
      SoundHost::failure = FailureMode::process;
      NotificationHost::started.clear();
      NotificationHost::succeeds = true;
      NotificationHost::failure = FailureMode::process;
    }

    [[qt::slot]] static void successfulAudioStopsAtTheFirstAvailableBackend() {
      Observer observer;
      SoundPlayer<SoundHost, Observer> player{observer};

      player.start(AgentSound::ready);
      QTRY_COMPARE_WITH_TIMEOUT(observer.results.size(), std::size_t{1}, wait_ms);
      QCOMPARE(SoundHost::started.size(), std::size_t{1});
      QVERIFY(!observer.results.front());
      QVERIFY(!player.active());
    }

    [[qt::slot]] static void failedBackendsRetainTheSemanticSoundAndStopAfterSuccess() {
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

    [[qt::slot]] static void exhaustingAllBackendsCompletesOnceAndPermitsTheNextSound() {
      SoundHost::successful_backend = SoundHost::attempts;
      Observer observer;
      SoundPlayer<SoundHost, Observer> player{observer};

      player.start(AgentSound::ready);
      QTRY_COMPARE_WITH_TIMEOUT(observer.results.size(), std::size_t{1}, wait_ms);
      QCOMPARE(SoundHost::started.size(), SoundHost::attempts);
      QCOMPARE(observer.results.front(), telar::ds::Option{CommandFailure::process});

      SoundHost::successful_backend = 0;
      player.start(AgentSound::needs_input);
      QTRY_COMPARE_WITH_TIMEOUT(observer.results.size(), std::size_t{2}, wait_ms);
      QCOMPARE(SoundHost::started.back().backend, std::size_t{0});
      QVERIFY(!observer.results.back());
    }

    [[qt::slot]] static void launchTimeoutAndOutputFailuresAlsoFallBack() {
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

    [[qt::slot]] static void aSecondStartCannotReplaceTheActiveAttempt() {
      SoundHost::successful_backend = 1;
      Observer observer;
      SoundPlayer<SoundHost, Observer> player{observer};

      player.start(AgentSound::needs_input);
      QVERIFY_THROWS_EXCEPTION(std::logic_error, player.start(AgentSound::ready));
      QTRY_COMPARE_WITH_TIMEOUT(observer.results.size(), std::size_t{1}, wait_ms);
      QCOMPARE(SoundHost::started.front().sound, AgentSound::needs_input);
      QCOMPARE(SoundHost::started.back().sound, AgentSound::needs_input);
    }

    [[qt::slot]] static void teardownCancelsDeferredAudioWithoutCallingTheHost() {
      Observer observer;

      {
        SoundPlayer<SoundHost, Observer> player{observer};

        player.start(AgentSound::ready);
      }

      QCoreApplication::processEvents();
      QVERIFY(SoundHost::started.empty());
      QVERIFY(observer.results.empty());
    }

    [[qt::slot]] static void completionMayDestroyThePlayer() {
      Observer observer;
      auto player = std::make_unique<SoundPlayer<SoundHost, Observer>>(observer);

      observer.completed = [&] {
        player.reset();
      };

      player->start(AgentSound::ready);
      QTRY_VERIFY_WITH_TIMEOUT(!player, wait_ms);
      QCOMPARE(observer.results.size(), std::size_t{1});
    }

    [[qt::slot]] static void noticesOwnDeferredPayloadAndReuseCompletedCapacity() {
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

    [[qt::slot]] static void desktopSaturationDropsNewWorkWithoutReplacingRetainedNotices() {
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
      for (const auto& notice : NotificationHost::started) {
        QCOMPARE(notice.title.view(), std::string_view{"Retained"});
      }
    }

    [[qt::slot]] static void desktopFailuresAreNotRetriedAndReleaseTheirSlot() {
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

    [[qt::slot]] static void desktopAdmissionUsesTheInjectedAllocatorAndReusesItsStorage() {
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

  using telar::gui::test::QtCase;

  const QtCase<HostEffectsTest, "successfulAudioStopsAtTheFirstAvailableBackend"> case_successful_audio_stops_at_the_first_available_backend{"host_effects.successful_audio_stops_at_the_first_available_backend"};
  const QtCase<HostEffectsTest, "failedBackendsRetainTheSemanticSoundAndStopAfterSuccess"> case_failed_backends_retain_the_semantic_sound_and_stop_after_success{"host_effects.failed_backends_retain_the_semantic_sound_and_stop_after_success"};
  const QtCase<HostEffectsTest, "exhaustingAllBackendsCompletesOnceAndPermitsTheNextSound"> case_exhausting_all_backends_completes_once_and_permits_the_next_sound{"host_effects.exhausting_all_backends_completes_once_and_permits_the_next_sound"};
  const QtCase<HostEffectsTest, "launchTimeoutAndOutputFailuresAlsoFallBack"> case_launch_timeout_and_output_failures_also_fall_back{"host_effects.launch_timeout_and_output_failures_also_fall_back"};
  const QtCase<HostEffectsTest, "aSecondStartCannotReplaceTheActiveAttempt"> case_a_second_start_cannot_replace_the_active_attempt{"host_effects.a_second_start_cannot_replace_the_active_attempt"};
  const QtCase<HostEffectsTest, "teardownCancelsDeferredAudioWithoutCallingTheHost"> case_teardown_cancels_deferred_audio_without_calling_the_host{"host_effects.teardown_cancels_deferred_audio_without_calling_the_host"};
  const QtCase<HostEffectsTest, "completionMayDestroyThePlayer"> case_completion_may_destroy_the_player{"host_effects.completion_may_destroy_the_player"};
  const QtCase<HostEffectsTest, "noticesOwnDeferredPayloadAndReuseCompletedCapacity"> case_notices_own_deferred_payload_and_reuse_completed_capacity{"host_effects.notices_own_deferred_payload_and_reuse_completed_capacity"};
  const QtCase<HostEffectsTest, "desktopSaturationDropsNewWorkWithoutReplacingRetainedNotices"> case_desktop_saturation_drops_new_work_without_replacing_retained_notices{"host_effects.desktop_saturation_drops_new_work_without_replacing_retained_notices"};
  const QtCase<HostEffectsTest, "desktopFailuresAreNotRetriedAndReleaseTheirSlot"> case_desktop_failures_are_not_retried_and_release_their_slot{"host_effects.desktop_failures_are_not_retried_and_release_their_slot"};
  const QtCase<HostEffectsTest, "desktopAdmissionUsesTheInjectedAllocatorAndReusesItsStorage"> case_desktop_admission_uses_the_injected_allocator_and_reuses_its_storage{"host_effects.desktop_admission_uses_the_injected_allocator_and_reuses_its_storage"};

}

#ifndef TELAR_MOC_RUN
#include "host_effects_test.moc"
#endif