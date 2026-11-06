#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../qt/external_link_opener.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <cstddef>
#include <cstdint>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <algorithm>
#include <limits>
#include <optional>
#include <array>
#include "../platform/environment.hpp"
#include "../qt/projection.hpp"
#include <QByteArray>
#include <QCoreApplication>
#include <QProcess>
#include <QString>
#include <QStringLiteral>
#include <QStringList>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qscopeguard.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/qtestcase.h>
#include <cerrno>
#include <chrono>
#include <stdexcept>
#include <unistd.h>
#include <sys/wait.h>
#include <utility>
#include <variant>
#include <vector>

#include "external_link_opener.hpp"
#include "platform/environment.hpp"
#include "projection.hpp"


import telar.gui.links.cell_links;
import telar.gui.platform.login_shell;

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;

struct Observer {
  std::vector<std::optional<LinkOpeningFailure>> results;

  void linkOpeningFinished([[maybe_unused]] std::monostate context, std::optional<LinkOpeningFailure> failure) {
    results.push_back(failure);
  }

  [[nodiscard]] bool waitFor(std::size_t count) const {
    return QTest::qWaitFor([&] {
      return results.size() == count;
    });
  }
};

struct ContextObserver {
  std::vector<std::pair<std::uint64_t, std::optional<LinkOpeningFailure>>> results;

  void linkOpeningFinished(std::uint64_t context, std::optional<LinkOpeningFailure> failure) {
    results.emplace_back(context, failure);
  }
};

struct TestHost {
  static constexpr auto timeout = std::chrono::seconds{1};
  inline static QStringList started;
  inline static qint64 process_id = 0;

  static void start(QProcess &process, const LinkTarget &target) {
    const auto text = toQString(target.text());
    started.push_back(text);
    QObject::connect(&process, &QProcess::started, &process, [&process] {
      process_id = process.processId();
    },
                     Qt::SingleShotConnection);
    if (text.contains(QStringLiteral("launch.test"))) {
      process.start(QStringLiteral("/"));

      return;
    }

    if (text.contains(QStringLiteral("throw.test"))) {
      throw std::runtime_error{"Injected host failure"};
    }

    if (text.contains(QStringLiteral("read-error.test"))) {
      QObject::connect(&process, &QProcess::started, &process, [&process] {
        process.errorOccurred(QProcess::ReadError);
      },
                       Qt::SingleShotConnection);
    }

    constexpr auto script = R"(
case "$1" in
  *slow.test*) sleep 0.02 ;;
  *timeout.test*) exec sleep 60 ;;
  *failure.test*) exit 7 ;;
  *stdout.test*) dd if=/dev/zero bs=4097 count=1 2>/dev/null; exit ;;
  *stderr.test*) dd if=/dev/zero bs=4097 count=1 1>&2 2>/dev/null; exit ;;
  *limit.test*) dd if=/dev/zero bs=4096 count=1 2>/dev/null; exit ;;
esac
printf '%s' "$1"
)";
    process.start(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), QString::fromLatin1(script), QStringLiteral("telar-link-test"), text}, QIODevice::ReadOnly);
  }
};

struct ShortDeadlineHost : TestHost {
  static constexpr auto timeout = std::chrono::milliseconds{100};
};

LinkTarget target(std::string_view text) {
  const auto result = LinkTarget::fromUri(text);
  if (!result) {
    throw std::runtime_error{"Invalid link-opening fixture"};
  }

  return *result;
}

class LinkOpenerTest : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void init() {
    TestHost::started.clear();
    TestHost::process_id = 0;
  }

  Q_SLOT static void lastPendingWins() {
    Observer observer;
    ExternalLinkOpener<TestHost, Observer> opener{observer};
    const auto first = target("https://slow.test");
    const auto omitted = target("https://omitted.test");
    const auto last = target("https://last.test");
    opener.request(first);
    opener.request(omitted);
    opener.request(last);
    QVERIFY(opener.active());
    QVERIFY(TestHost::started.empty());
    QVERIFY(observer.waitFor(2));
    QVERIFY(!opener.active());
    QCOMPARE(TestHost::started, (QStringList{toQString(first.text()), toQString(last.text())}));
    QVERIFY(!observer.results.front() && !observer.results.back());
  }

  Q_SLOT static void completionsKeepTheirOriginalContext() {
    ContextObserver observer;
    ExternalLinkOpener<TestHost, ContextObserver, std::uint64_t> opener{observer};
    constexpr std::uint64_t first_context = 11;
    constexpr std::uint64_t replaced_context = 12;
    constexpr std::uint64_t last_context = 13;
    opener.request(target("https://failure.test"), first_context);
    opener.request(target("https://omitted.test"), replaced_context);
    opener.request(target("https://last.test"), last_context);
    QVERIFY(QTest::qWaitFor([&] {
      return observer.results.size() == 2;
    }));
    QCOMPARE(observer.results[0].first, first_context);
    QCOMPARE(observer.results[0].second, std::optional{LinkOpeningFailure::process});
    QCOMPARE(observer.results[1].first, last_context);
    QVERIFY(!observer.results[1].second);
  }

  Q_SLOT static void failuresAndRecovery() {
    Observer observer;
    ExternalLinkOpener<TestHost, Observer> opener{observer};
    opener.request(target("https://failure.test"));
    opener.request(target("https://recovery.test"));
    QVERIFY(observer.waitFor(2));
    QCOMPARE(observer.results.front(), std::optional{LinkOpeningFailure::process});
    QVERIFY(!observer.results.back() && !opener.active());
    opener.request(target("https://launch.test"));
    QVERIFY(observer.waitFor(3));
    QCOMPARE(observer.results.back(), std::optional{LinkOpeningFailure::launch});
    opener.request(target("https://throw.test"));
    QVERIFY(observer.waitFor(4));
    QCOMPARE(observer.results.back(), std::optional{LinkOpeningFailure::launch});
    QVERIFY(!opener.active());
    opener.request(target("https://read-error.test"));
    opener.request(target("https://recovered.test"));
    constexpr std::size_t completed_requests = 6;
    QVERIFY(observer.waitFor(completed_requests));
    QCOMPARE(observer.results[completed_requests - 2], std::optional{LinkOpeningFailure::process});
    QVERIFY(!observer.results.back() && !opener.active());
  }

  Q_SLOT static void outputLimits() {
    Observer observer;
    ExternalLinkOpener<TestHost, Observer> opener{observer};
    opener.request(target("https://stdout.test"));
    QVERIFY(observer.waitFor(1));
    QCOMPARE(observer.results.back(), std::optional{LinkOpeningFailure::output_limit});
    opener.request(target("https://stderr.test"));
    QVERIFY(observer.waitFor(2));
    QCOMPARE(observer.results.back(), std::optional{LinkOpeningFailure::output_limit});
    opener.request(target("https://limit.test"));
    QVERIFY(observer.waitFor(3));
    QVERIFY(!observer.results.back());
  }

  Q_SLOT static void timeoutAndShutdown() {
    Observer observer;
    {
      ExternalLinkOpener<ShortDeadlineHost, Observer> opener{observer};
      opener.request(target("https://timeout.test"));
      opener.request(target("https://recovered.test"));
      QVERIFY(observer.waitFor(2));
      QCOMPARE(observer.results.front(), std::optional{LinkOpeningFailure::timeout});
      QVERIFY(!observer.results.back() && !opener.active());
    }

    observer.results.clear();
    {
      ExternalLinkOpener<TestHost, Observer> opener{observer};
      TestHost::process_id = 0;
      opener.request(target("https://timeout.test"));
      opener.request(target("https://must-not-open.test"));
      QTRY_VERIFY(TestHost::process_id != 0);
    }

    QVERIFY(observer.results.empty());
    QVERIFY(!TestHost::started.contains(QStringLiteral("https://must-not-open.test")));
    QCOMPARE(::waitpid(static_cast<decltype(::getpid())>(TestHost::process_id), nullptr, WNOHANG), -1);
    QCOMPARE(errno, ECHILD);
  }

  Q_SLOT static void argumentAuthority() {
    Observer observer;
    ExternalLinkOpener<TestHost, Observer> opener{observer};
    const auto literal = target("https://literal.test/$(id);date");
    opener.request(literal);
    QVERIFY(observer.waitFor(1));
    QCOMPARE(TestHost::started.front(), toQString(literal.text()));
    QVERIFY(!observer.results.back());
    QVERIFY_THROWS_EXCEPTION(std::invalid_argument, opener.request(target("file:///tmp/a")));
    QVERIFY(!opener.active());
    QCOMPARE(platform::AppleExternalLinks::executable, std::string_view{"/usr/bin/open"});
    QCOMPARE(platform::LinuxExternalLinks::executable, std::string_view{"xdg-open"});
  }

  Q_SLOT static void environmentAuthority() {
    constexpr auto name = "TELAR_GUI_TEST_ENVIRONMENT";
    const auto previous = qgetenv(name);
    const auto restore = qScopeGuard([previous] {
      if (previous.isNull()) {
        static_cast<void>(qunsetenv(name));
      } else {
        static_cast<void>(qputenv(name, previous));
      }
    });
    QVERIFY(qunsetenv(name));
    const platform::ProcessEnvironment missing;
    QVERIFY(!missing(name));
    QVERIFY(qputenv(name, QByteArray{""}));
    const platform::ProcessEnvironment empty;
    const auto empty_value = empty(name);
    QVERIFY(empty_value && empty_value->empty());
    constexpr std::string_view raw_byte = "\xff";
    QVERIFY(qputenv(name, QByteArray{raw_byte.data(), static_cast<qsizetype>(raw_byte.size())}));
    const platform::ProcessEnvironment captured;
    const auto retained = captured(name);
    QVERIFY(retained && *retained == raw_byte);
    QVERIFY(qputenv(name, QByteArray{"changed"}));
    QVERIFY(captured(name) == retained && retained == std::optional{raw_byte});
    const platform::ProcessEnvironment replacement;
    QVERIFY(replacement(name) == std::optional{std::string_view{"changed"}});
  }
};

}

int main(int argc, char **argv) {
  const QCoreApplication application{argc, argv};
  LinkOpenerTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "link_opener_test.moc"
