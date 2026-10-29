#include "appearance_fixture.hpp"
#include "application/client_view_state.hpp"
#include "application/dependencies.hpp"
#include "config/callback.hpp"
#include "config/query.hpp"
#include "config/themes.hpp"
#include "core/color.hpp"
#include "core/configuration.hpp"
#include "core/theme_values.hpp"
#include "input/action.hpp"
#include "input/configuration.hpp"
#include "json_fixture.hpp"
#include "qt/configuration_source.hpp"
#include "text/json.hpp"
#include "ui/bundled_fonts.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QIODevice>
#include <QObject>
#include <QSemaphore>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QThreadPool>
#include <QTimer>
#include <QtCore/qnamespace.h>
#include <QtCore/qstring.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtTest/qtestcase.h>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

using telar::gui::test::AppearanceFixture;
using telar::gui::test::requiredJsonField;

using namespace telar::gui;
using namespace telar::gui::qt;

constexpr auto valid_configuration = "return {api_version=2, client={sidebar={visible=false}}}";
constexpr auto visible_configuration = "return {api_version=2, client={sidebar={visible=true}}}";
constexpr auto deferred_module_configuration = "return {api_version=2,client={keybindings={telar.bind_global({'s'},function() return require('nested.action')() end)}}}";
constexpr auto toggle_module = "return function() return telar.action.toggle_sidebar() end";
constexpr auto fullscreen_module = "return function() return telar.action.toggle_pane_fullscreen() end";
constexpr auto stateful_configuration = "local calls=0; return {api_version=2,client={keybindings={telar.bind_global({'s'},function() calls=calls+1; return telar.action.select_tab{index=calls} end)}}}";

void writeFile(const QString &path, const char *text) {
  QFile file{path};
  if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate) || file.write(text) < 0) {
    throw std::runtime_error{"Cannot write configuration source fixture"};
  }
}

class PausedThreadPool {
public:
  PausedThreadPool()
      : pool_(*QThreadPool::globalInstance()),
        previous_threads_(pool_.maxThreadCount()) {
    pool_.setMaxThreadCount(1);
    pool_.start([this] {
      started_.release();
      resume_.acquire();
    });
    started_.acquire();
  }

  ~PausedThreadPool() {
    resume_.release();
    pool_.waitForDone();
    pool_.setMaxThreadCount(previous_threads_);
  }

  PausedThreadPool(const PausedThreadPool &) = delete;
  PausedThreadPool &operator=(const PausedThreadPool &) = delete;
  PausedThreadPool(PausedThreadPool &&) = delete;
  PausedThreadPool &operator=(PausedThreadPool &&) = delete;

  void resume() {
    resume_.release();
  }

  void finish() {
    resume();
    pool_.waitForDone();
    QCoreApplication::processEvents();
  }

private:
  QThreadPool &pool_;
  int previous_threads_;
  QSemaphore started_;
  QSemaphore resume_;
};

struct ConfigurationOwner {
  ApplicationAllocator memory;
  ConfigurationSource source{memory};
};

class ConfigurationSourceTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void clientQueriesTrackAdoptionAndLiveState() {
    const QTemporaryDir directory;
    const auto absolute_path = directory.filePath(QStringLiteral("config.lua"));
    const auto path = QDir::current().relativeFilePath(absolute_path);
    const QByteArray valid{"return {api_version=2,client={sound={enabled=false}},profiles={chosen={client={notifications={delivery='system'}}}}}"};
    writeFile(absolute_path, valid);
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QStringLiteral("chosen"), .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    constexpr std::uint16_t sidebar_columns = 61;
    const ClientViewState view{.sidebar_visible = false, .sidebar_width = sidebar_columns, .workspace_list_collapsed = true, .pane_gaps = false, .window_title = "{tab}"};
    const ConfigurationQuery query{.section = ConfigurationQuery::Section::client, .index = -1};
    const std::string before{source.query(query, view)};
    const auto parsed = telar::runtime::JsonValue::parse(before);
    const auto expected_path = path.toUtf8();
    QVERIFY(requiredJsonField(parsed, "source").equals({expected_path.constData(), static_cast<std::size_t>(expected_path.size())}));
    QVERIFY(requiredJsonField(parsed, "profile").equals("chosen"));
    QCOMPARE(requiredJsonField(parsed, "generation").encoded(), std::string_view{"1"});
    QVERIFY(!requiredJsonField(parsed, "sidebar_visible").boolean());
    QVERIFY(requiredJsonField(parsed, "workspace_list_collapsed").boolean());
    QCOMPARE(requiredJsonField(parsed, "sidebar_width").encoded(), std::string_view{"61"});
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    source.poll();
    QTRY_COMPARE(QThreadPool::globalInstance()->activeThreadCount(), 0);
    const QSignalSpy failures{&source, &ConfigurationSource::failed};
    writeFile(absolute_path, "return {api_version=2,client={sound={enabled='invalid'}}}");
    source.requestReload();
    QTRY_COMPARE(failures.count(), 1);
    QCOMPARE(source.query(query, view), std::string_view{before});
    writeFile(absolute_path, valid);
    source.requestReload();
    QTRY_COMPARE(changes.count(), 1);
    auto replaced = telar::runtime::JsonValue::parse(source.query(query, view));
    QCOMPARE(requiredJsonField(replaced, "generation").encoded(), std::string_view{"2"});
    source.open({.path = QString{}, .profile = QString{}, .theme = QString{}});
    QVERIFY_THROWS_EXCEPTION(std::runtime_error, static_cast<void>(source.query(query, view)));
    source.open({.path = path, .profile = QStringLiteral("chosen"), .theme = QString{}});
    replaced = telar::runtime::JsonValue::parse(source.query(query, view));
    QCOMPARE(requiredJsonField(replaced, "generation").encoded(), std::string_view{"3"});
  }

  Q_SLOT static void bindingQueriesRetainTheAdoptedGeneration() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, "return {api_version=2,client={keybindings={telar.bind({'c'},telar.action.command_tab{command={'echo','kept'},label='original'})}}}");
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    const ConfigurationQuery query{.section = ConfigurationQuery::Section::binding};
    const std::string before{source.query(query)};
    QVERIFY(before.contains(R"("label":"original","argv":["echo","kept"])"));
    const QSignalSpy failures{&source, &ConfigurationSource::failed};
    writeFile(path, "return {api_version=2,client={keybindings={telar.bind({'c'},telar.action.command_tab{command={}})}}}");
    source.requestReload();
    QTRY_COMPARE(failures.count(), 1);
    QCOMPARE(source.query(query), std::string_view{before});
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    writeFile(path, "return {api_version=2,client={keybindings={telar.bind_global({'n'},telar.action.new_tab())}}}");
    source.requestReload();
    QTRY_COMPARE(changes.count(), 1);
    QVERIFY(source.query(query).contains(R"("type":"new_tab","value":null)"));
    QVERIFY_THROWS_EXCEPTION(std::runtime_error, static_cast<void>(source.query({.section = ConfigurationQuery::Section::binding, .index = 1})));
    QVERIFY_THROWS_EXCEPTION(std::invalid_argument, static_cast<void>(source.query({.section = ConfigurationQuery::Section::binding, .index = -1})));
  }

  Q_SLOT static void bindingQueryErrorsPreserveAuthority() {
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    QVERIFY_THROWS_EXCEPTION(std::runtime_error, static_cast<void>(source.query({.section = ConfigurationQuery::Section::binding, .index = -1})));
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, "return {api_version=2}");
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    QVERIFY_THROWS_EXCEPTION(std::runtime_error, static_cast<void>(source.query({.section = ConfigurationQuery::Section::binding})));
    QVERIFY_THROWS_EXCEPTION(std::runtime_error, static_cast<void>(source.query({.section = ConfigurationQuery::Section::binding, .index = std::numeric_limits<std::int64_t>::max()})));
  }

  Q_SLOT static void appearanceEventsPreserveTheAdoptedGeneration() {
    const AppearanceFixture appearance;
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, "local n=0;return {api_version=2,theme='terminal',client={appearance={light={colors={text='#010203'}}},keybindings={telar.bind({'s'},function() n=n+1;return telar.action.select_tab{index=n} end)}}}");
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    AppearanceFixture::set(Qt::ColorScheme::Unknown);
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    const ConfigurationQuery query{.section = ConfigurationQuery::Section::theme};
    const std::string before{source.query(query)};
    const auto callback = source.input().configured.front().action;
    QCOMPARE(source.invoke(callback, {}).actions.front().parameter, 0);
    const QSignalSpy configuration_changes{&source, &ConfigurationSource::changed};
    const QSignalSpy theme_changes{&source, &ConfigurationSource::themeChanged};
    AppearanceFixture::set(Qt::ColorScheme::Light);
    constexpr auto light_text = Color::rgb(0x010203);
    QCOMPARE(source.configuration().theme.chromeColor(PaletteRole::text), light_text);
    QCOMPARE(theme_changes.count(), 1);
    AppearanceFixture::set(Qt::ColorScheme::Light);
    QCOMPARE(theme_changes.count(), 1);
    QCOMPARE(source.query(query), std::string_view{before});
    QCOMPARE(source.invoke(callback, {}).actions.front().parameter, 1);
    AppearanceFixture::set(Qt::ColorScheme::Dark);
    QCOMPARE(source.configuration().theme, themeByName("terminal"));
    QCOMPARE(theme_changes.count(), 2);
    QCOMPARE(configuration_changes.count(), 0);
  }

  Q_SLOT static void cliThemeLocksSurviveAppearanceAndFailedReload() {
    const AppearanceFixture appearance;
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, "return {api_version=2,theme='catppuccin',client={appearance={light='vesper',dark='kanagawa'}}}");
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QStringLiteral("shade")});
    QCOMPARE(source.error(), QString{});
    const auto locked = themeByName("shade");
    const QSignalSpy theme_changes{&source, &ConfigurationSource::themeChanged};
    AppearanceFixture::set(Qt::ColorScheme::Light);
    QCOMPARE(source.configuration().theme, locked);
    AppearanceFixture::set(Qt::ColorScheme::Dark);
    QCOMPARE(source.configuration().theme, locked);
    const QSignalSpy failures{&source, &ConfigurationSource::failed};
    writeFile(path, "return {api_version=2,theme={colors={text='invalid'}}}");
    source.requestReload();
    QTRY_COMPARE(failures.count(), 1);
    AppearanceFixture::set(Qt::ColorScheme::Unknown);
    QCOMPARE(source.configuration().theme, locked);
    QCOMPARE(theme_changes.count(), 0);
  }

  Q_SLOT static void guiAndInputQueriesRetainAdoptedProfiles() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, "return {api_version=2,gui={font={size=16}},client={prefix='ctrl+b'},profiles={selected={gui={font={size=18.25}},client={prefix='shift+tab'}}}}");
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QStringLiteral("selected"), .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    const ConfigurationQuery gui_query{.section = ConfigurationQuery::Section::gui};
    const ConfigurationQuery input_query{.section = ConfigurationQuery::Section::input};
    const std::string saved_gui{source.query(gui_query)};
    const std::string saved_input{source.query(input_query)};
    const auto gui = telar::runtime::JsonValue::parse(saved_gui);
    const auto input = telar::runtime::JsonValue::parse(saved_input);
    QCOMPARE(requiredJsonField(requiredJsonField(gui, "font"), "size").encoded(), std::string_view{"18.25"});
    QCOMPARE(requiredJsonField(requiredJsonField(input, "prefix"), "code").encoded(), std::string_view{R"({"back_tab":{}})"});
    const QSignalSpy failures{&source, &ConfigurationSource::failed};
    writeFile(path, "return {api_version=2,gui={font={size=42}},profiles={selected={},unused={runtime={graphics={pane_mib=0}}}}}");
    source.requestReload();
    QTRY_COMPARE(failures.count(), 1);
    QCOMPARE(source.query(gui_query), std::string_view{saved_gui});
    QCOMPARE(source.query(input_query), std::string_view{saved_input});
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    writeFile(path, "return {api_version=2,gui={font={size=20.25}},profiles={selected={}}}");
    source.requestReload();
    QTRY_COMPARE(changes.count(), 1);
    const auto replaced = telar::runtime::JsonValue::parse(source.query(gui_query));
    QCOMPARE(requiredJsonField(requiredJsonField(replaced, "font"), "size").encoded(), std::string_view{"20.25"});
    QCOMPARE(source.error(), QString{});
  }

  Q_SLOT static void guiAndInputQueryErrorsPreserveAuthority() {
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    for (const auto section : {ConfigurationQuery::Section::gui, ConfigurationQuery::Section::input}) {
      QVERIFY_THROWS_EXCEPTION(std::runtime_error, static_cast<void>(source.query({.section = section, .index = -1})));
    }

    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, "return {api_version=2}");
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    for (const auto section : {ConfigurationQuery::Section::gui, ConfigurationQuery::Section::input}) {
      QVERIFY_THROWS_EXCEPTION(std::invalid_argument, static_cast<void>(source.query({.section = section, .index = -1})));
      QVERIFY(!source.query({.section = section}).empty());
    }
  }

  Q_SLOT static void runtimeQueriesRetainAdoptedValuesAfterFailedReload() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, "return {api_version=2,runtime={history={path='retained.db'},session={persist=false}}}");
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    const ConfigurationQuery query{.section = ConfigurationQuery::Section::runtime};
    auto parsed = telar::runtime::JsonValue::parse(source.query(query));
    QVERIFY(requiredJsonField(parsed, "history_path").equals("retained.db"));
    QVERIFY(!requiredJsonField(parsed, "session_persist").boolean());
    const QSignalSpy failures{&source, &ConfigurationSource::failed};
    writeFile(path, "return {api_version=2,runtime={graphics={pane_mib=0}}}");
    source.poll();
    QTRY_COMPARE(failures.count(), 1);
    parsed = telar::runtime::JsonValue::parse(source.query(query));
    QVERIFY(requiredJsonField(parsed, "history_path").equals("retained.db"));
    QVERIFY(!requiredJsonField(parsed, "session_persist").boolean());
    writeFile(path, "return {api_version=2,runtime={history={path='replacement.db'}}}");
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    source.requestReload();
    QTRY_COMPARE(changes.count(), 1);
    parsed = telar::runtime::JsonValue::parse(source.query(query));
    QVERIFY(requiredJsonField(parsed, "history_path").equals("replacement.db"));
    QVERIFY(requiredJsonField(parsed, "session_persist").boolean());
  }

  Q_SLOT static void runtimeQueryErrorsPreserveAuthority() {
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    const ConfigurationQuery query{.section = ConfigurationQuery::Section::runtime, .index = -1};
    QVERIFY_THROWS_EXCEPTION(std::runtime_error, static_cast<void>(source.query(query)));
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, "return {api_version=2}");
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    QVERIFY_THROWS_EXCEPTION(std::invalid_argument, static_cast<void>(source.query(query)));
    QVERIFY_THROWS_EXCEPTION(std::invalid_argument, static_cast<void>(ConfigurationQuery::parse("Runtime", 0)));
    QVERIFY(!source.query({.section = ConfigurationQuery::Section::runtime}).empty());
  }

  Q_SLOT static void rootChangesAndForcedReload() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, valid_configuration);
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    writeFile(path, visible_configuration);
    source.poll();
    QTRY_COMPARE(changes.count(), 1);
    QVERIFY(source.configuration().sidebar_visible);
    source.poll();
    QTRY_COMPARE(changes.count(), 1);
    source.requestReload();
    QTRY_COMPARE(changes.count(), 2);
  }

  Q_SLOT static void nestedDependenciesAndFailureRecovery() {
    const QTemporaryDir directory;
    QVERIFY(QDir{directory.path()}.mkpath(QStringLiteral("nested")));
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    const auto dependency = directory.filePath(QStringLiteral("nested/preferences.lua"));
    writeFile(path, "return require('nested.preferences')");
    writeFile(dependency, valid_configuration);
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    const QSignalSpy failures{&source, &ConfigurationSource::failed};
    writeFile(dependency, visible_configuration);
    source.poll();
    QTRY_COMPARE(changes.count(), 1);
    QVERIFY(source.configuration().sidebar_visible);
    QVERIFY(QFile::remove(dependency));
    source.poll();
    QTRY_COMPARE(failures.count(), 1);
    QVERIFY(source.configuration().sidebar_visible);
    source.poll();
    QTRY_COMPARE(failures.count(), 1);
    writeFile(dependency, valid_configuration);
    source.poll();
    QTRY_COMPARE(changes.count(), 2);
    QVERIFY(!source.configuration().sidebar_visible);
  }

  Q_SLOT static void modulesLoadedByCallbacksRemainWatched() {
    const QTemporaryDir directory;
    QVERIFY(QDir{directory.path()}.mkpath(QStringLiteral("nested")));
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    const auto dependency = directory.filePath(QStringLiteral("nested/action.lua"));
    writeFile(path, deferred_module_configuration);
    writeFile(dependency, toggle_module);
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    const auto first = source.invoke(source.input().configured[0].action, {});
    QCOMPARE(first.actions[0].kind, BindingActionKind::toggle_sidebar);
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    writeFile(dependency, fullscreen_module);
    source.poll();
    QTRY_COMPARE(changes.count(), 1);
    const auto second = source.invoke(source.input().configured[0].action, {});
    QCOMPARE(second.actions[0].kind, BindingActionKind::toggle_pane_fullscreen);
  }

  Q_SLOT static void failedCallbacksKeepTheirLoadedDependencies() {
    const QTemporaryDir directory;
    QVERIFY(QDir{directory.path()}.mkpath(QStringLiteral("nested")));
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    const auto dependency = directory.filePath(QStringLiteral("nested/action.lua"));
    writeFile(path, deferred_module_configuration);
    writeFile(dependency, "return function() error('fixture failure') end");
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    QVERIFY_THROWS_EXCEPTION(std::exception, static_cast<void>(source.invoke(source.input().configured[0].action, {})));
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    writeFile(dependency, toggle_module);
    source.poll();
    QTRY_COMPARE(changes.count(), 1);
    const auto effects = source.invoke(source.input().configured[0].action, {});
    QCOMPARE(effects.actions[0].kind, BindingActionKind::toggle_sidebar);
  }

  Q_SLOT static void unrelatedChangesPreserveCallbackState() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, stateful_configuration);
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    const auto first = source.invoke(source.input().configured[0].action, {});
    QCOMPARE(first.actions[0].parameter, std::uint64_t{0});
    writeFile(directory.filePath(QStringLiteral("unused.lua")), "return {}");
    source.poll();
    const auto second = source.invoke(source.input().configured[0].action, {});
    QCOMPARE(second.actions[0].parameter, std::uint64_t{1});
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    source.requestReload();
    QTRY_COMPARE(changes.count(), 1);
    const auto reset = source.invoke(source.input().configured[0].action, {});
    QCOMPARE(reset.actions[0].parameter, std::uint64_t{0});
  }

  Q_SLOT static void unrelatedDirectoryChangePreservesGeneration() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, valid_configuration);
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    writeFile(directory.filePath(QStringLiteral("unrelated.txt")), "unrelated contents");
    constexpr int dependency_poll_wait_ms = 1200;
    QTest::qWait(dependency_poll_wait_ms);
    QCOMPARE(changes.count(), 0);
  }

  Q_SLOT static void pendingReloadPreservesActiveGenerationAndEventLoop() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, valid_configuration);
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    QCOMPARE(source.error(), QString{});
    PausedThreadPool pool;
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    writeFile(path, visible_configuration);
    source.poll();
    QCOMPARE(changes.count(), 0);
    QVERIFY(!source.configuration().sidebar_visible);
    bool heartbeat = false;
    QTimer::singleShot(0, &source, [&] {
      heartbeat = true;
    });
    QTRY_VERIFY(heartbeat);
    QCOMPARE(changes.count(), 0);
    pool.resume();
    QTRY_COMPARE(changes.count(), 1);
    QVERIFY(source.configuration().sidebar_visible);
  }

  Q_SLOT static void latestForcedReloadSupersedesPendingCheck() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, valid_configuration);
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    PausedThreadPool pool;
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    source.poll();
    writeFile(path, visible_configuration);
    constexpr int repeated_requests = 3;
    for (int request = 0; request < repeated_requests; ++request) {
      source.requestReload();
    }

    constexpr int debounce_wait_ms = 150;
    QTest::qWait(debounce_wait_ms);
    QCOMPARE(changes.count(), 0);
    QVERIFY(!source.configuration().sidebar_visible);
    pool.resume();
    QTRY_COMPARE(changes.count(), 1);
    QVERIFY(source.configuration().sidebar_visible);
    QTest::qWait(debounce_wait_ms);
    QCOMPARE(changes.count(), 1);
  }

  Q_SLOT static void switchingSourceRejectsLateResult() {
    const QTemporaryDir directory;
    const auto first = directory.filePath(QStringLiteral("first.lua"));
    const auto second = directory.filePath(QStringLiteral("second.lua"));
    writeFile(first, valid_configuration);
    writeFile(second, visible_configuration);
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = first, .profile = QString{}, .theme = QString{}});
    PausedThreadPool pool;
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    const QSignalSpy failures{&source, &ConfigurationSource::failed};
    writeFile(first, "invalid configuration");
    source.poll();
    source.open({.path = second, .profile = QString{}, .theme = QString{}});
    QCOMPARE(changes.count(), 1);
    pool.finish();
    QCOMPARE(changes.count(), 1);
    QCOMPARE(failures.count(), 0);
    QCOMPARE(source.error(), QString{});
    QVERIFY(source.configuration().sidebar_visible);
  }

  Q_SLOT static void callbackDependenciesAddedDuringCheckRemainWatched() {
    const QTemporaryDir directory;
    QVERIFY(QDir{directory.path()}.mkpath(QStringLiteral("nested")));
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    const auto dependency = directory.filePath(QStringLiteral("nested/action.lua"));
    writeFile(path, deferred_module_configuration);
    writeFile(dependency, toggle_module);
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    PausedThreadPool pool;
    source.poll();
    const auto effects = source.invoke(source.input().configured[0].action, {});
    QCOMPARE(effects.actions[0].kind, BindingActionKind::toggle_sidebar);
    pool.finish();
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    writeFile(dependency, fullscreen_module);
    source.poll();
    QTRY_COMPARE(changes.count(), 1);
    const auto updated = source.invoke(source.input().configured[0].action, {});
    QCOMPARE(updated.actions[0].kind, BindingActionKind::toggle_pane_fullscreen);
  }

  Q_SLOT static void failedReloadPreservesCallbackState() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, stateful_configuration);
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    const auto action = source.input().configured[0].action;
    const auto first = source.invoke(action, {});
    QCOMPARE(first.actions[0].parameter, std::uint64_t{0});
    const QSignalSpy failures{&source, &ConfigurationSource::failed};
    writeFile(path, "invalid configuration");
    source.poll();
    QTRY_COMPARE(failures.count(), 1);
    const auto retained = source.invoke(action, {});
    QCOMPARE(retained.actions[0].parameter, std::uint64_t{1});
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    writeFile(path, stateful_configuration);
    source.poll();
    QTRY_COMPARE(changes.count(), 1);
    QVERIFY_THROWS_EXCEPTION(std::invalid_argument, static_cast<void>(source.invoke(action, {})));
    const auto replacement = source.invoke(source.input().configured[0].action, {});
    QCOMPARE(replacement.actions[0].parameter, std::uint64_t{0});
  }

  Q_SLOT static void destructionWaitsForWorkerAndDiscardsNotification() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, valid_configuration);
    ApplicationAllocator memory;
    auto source = std::make_unique<ConfigurationSource>(memory);
    source->open({.path = path, .profile = QString{}, .theme = QString{}});
    PausedThreadPool pool;
    const QObject receiver;
    bool changed = false;
    connect(source.get(), &ConfigurationSource::changed, &receiver, [&] {
      changed = true;
    });
    writeFile(path, visible_configuration);
    source->poll();
    pool.resume();
    source.reset();
    QCoreApplication::processEvents();
    QVERIFY(!changed);
  }

  Q_SLOT static void fontValidationFailurePreservesGeneration() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, valid_configuration);
    ApplicationAllocator memory;
    ConfigurationSource source{memory};
    source.open({.path = path, .profile = QString{}, .theme = QString{}});
    const QSignalSpy changes{&source, &ConfigurationSource::changed};
    const QSignalSpy failures{&source, &ConfigurationSource::failed};
    writeFile(path, "return {api_version=2,gui={font={family='Telar Missing Font Fixture'}},client={sidebar={visible=true}}}");
    source.poll();
    QTRY_COMPARE(failures.count(), 1);
    QCOMPARE(changes.count(), 0);
    QVERIFY(!source.configuration().sidebar_visible);
    QVERIFY(!source.error().isEmpty());
  }

  Q_SLOT static void adoptionCanDestroySourceAndAllocator() {
    const QTemporaryDir directory;
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    writeFile(path, valid_configuration);
    auto owner = std::make_unique<ConfigurationOwner>();
    owner->source.open({.path = path, .profile = QString{}, .theme = QString{}});
    const QObject receiver;
    connect(&owner->source, &ConfigurationSource::changed, &receiver, [&] {
      owner.reset();
    });
    writeFile(path, visible_configuration);
    owner->source.poll();
    QTRY_VERIFY(owner == nullptr);
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  ui::bundledFonts();
  ConfigurationSourceTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "configuration_source_test.moc"
