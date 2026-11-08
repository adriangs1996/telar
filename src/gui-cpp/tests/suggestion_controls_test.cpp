#include "application/dependencies.hpp"
#include "frame_fixture.hpp"
#include "qml_fixture.hpp"
#include "qt/application.hpp"
#include "qt/key_adapter.hpp"
#include "qt/list_model.hpp"
#include "qt/native_form_field.hpp"
#include "qt/terminal_item.hpp"
#include "screen_fixture.hpp"
#include "qt/bundled_fonts.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QObject>
#include <QProcess>
#include <QProcessEnvironment>
#include <QQmlEngine>
#include <QQmlError>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QVariantMap>
#include <QtCore/qbytearrayview.h>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qlatin1stringview.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestkeyboard.h>
#include <QtTest/qtestmouse.h>
#include <cstdint>
#include <memory>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;
using telar::gui::test::screenText;
using telar::gui::test::ScreenTextLayout;

constexpr int wait_ms = 10'000;
constexpr int window_width = 1000;
constexpr int window_height = 640;

QString luaLiteral(const QString &text) {
  QString delimiter;
  while (text.contains(QLatin1Char(']') + delimiter + QLatin1Char(']'))) {
    delimiter += QLatin1Char('=');
  }

  return QLatin1Char('[') + delimiter + QLatin1Char('[') + text + QLatin1Char(']') + delimiter + QLatin1Char(']');
}

class SuggestionControlsTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT void initTestCase() {
    QVERIFY(directory_.isValid());
    marker_ = directory_.filePath(QStringLiteral("suggestion-ran"));
    socket_ = directory_.filePath(QStringLiteral("runtime.sock"));
    const auto configuration = directory_.filePath(QStringLiteral("config.lua"));
    const auto command = QStringLiteral("return {api_version=2,runtime={session={persist=false},engine={timeout_ms=1000,command={%1,%2,%3}}}}")
                             .arg(luaLiteral(QString::fromUtf8(TELAR_GUI_TEST_PYTHON)), luaLiteral(QString::fromUtf8(TELAR_GUI_SUGGESTION_FIXTURE)), luaLiteral(marker_))
                             .toUtf8();
    QFile file{configuration};
    QVERIFY(file.open(QIODevice::WriteOnly));
    QCOMPARE(file.write(command), command.size());
    file.close();
    auto environment = QProcessEnvironment::systemEnvironment();
    for (const auto &name : environment.keys()) {
      if (name.startsWith(QLatin1StringView("TELAR_"))) {
        environment.remove(name);
      }
    }

    environment.remove(QStringLiteral("ENV"));
    environment.remove(QStringLiteral("BASH_ENV"));
    environment.insert(QStringLiteral("XDG_DATA_HOME"), directory_.filePath(QStringLiteral("data")));
    environment.insert(QStringLiteral("XDG_CONFIG_HOME"), directory_.filePath(QStringLiteral("config")));
    runtime_.setProgram(qEnvironmentVariable("TELAR_GUI_TEST_RUNTIME"));
    runtime_.setArguments({QStringLiteral("server"), QStringLiteral("--fresh"), QStringLiteral("--config"), configuration, QStringLiteral("--socket"), socket_});
    runtime_.setWorkingDirectory(directory_.path());
    runtime_.setProcessEnvironment(environment);
    runtime_.start();
    QVERIFY(runtime_.waitForStarted());
    QTRY_VERIFY2_WITH_TIMEOUT(QFileInfo::exists(socket_), runtime_.readAllStandardError().constData(), wait_ms);
    bundledFonts();
    client_ = std::make_unique<Application>(memory_);
    client_->configureLaunch(directory_.path(), {QStringLiteral("/bin/sh")}, false);
    client_->loadConfiguration(configuration, {}, {});
    window_->resize(window_width, window_height);
    client_->setWindow(*window_);
    client_->open(socket_);
    QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rowCount(), 1, wait_ms);
    const auto record = client_->panes()->data(client_->panes()->index(0, 0), ListModel::record_role).toMap();
    pane_id_ = record.value(QStringLiteral("key")).toString().toULongLong();
    terminal_ = std::make_unique<TerminalItem>(window_->contentItem());
    terminal_->setApplication(client_.get());
    terminal_->setPaneId(QString::number(pane_id_));
    connect(&engine_, &QQmlEngine::warnings, this, [this](const QList<QQmlError> &errors) {
      for (const auto &error : errors) {
        errors_ += error.toString() + QLatin1Char('\n');
      }
    });
    panel_ = test::createChrome(engine_, QStringLiteral("PalettePanel"), {{QStringLiteral("controller"), QVariant::fromValue(client_.get())}, {QStringLiteral("ratio"), client_->chromeRatio()}});
    panel_->setParentItem(window_->contentItem());
    connect(client_.get(), &Application::windowGeometryChanged, this, &SuggestionControlsTest::synchronizeSurfaces);
    connect(client_.get(), &Application::paletteChanged, this, &SuggestionControlsTest::synchronizeSurfaces);
    connect(client_.get(), &Application::dialogChanged, this, &SuggestionControlsTest::synchronizeSurfaces);
    synchronizeSurfaces();
    QVERIFY(test::showComponentWindow(*window_, wait_ms));
    QTRY_VERIFY_WITH_TIMEOUT(client_->pane(pane_id_) != nullptr && client_->pane(pane_id_)->screen.frameId() != 0, wait_ms);
  }

  Q_SLOT void defaultShortcutOpensTheSuggestionEditor() {
    terminal_->forceActiveFocus();
    QVERIFY(terminal_->hasActiveFocus());
    QTest::keyClick(window_.get(), Qt::Key_B, NativeKeyAdapter::control_modifier);
    QVERIFY2(client_->prefixPending(), qPrintable(client_->error()));
    QTest::keyClick(window_.get(), Qt::Key_Question);
    QTRY_COMPARE_WITH_TIMEOUT(client_->dialog(), QStringLiteral("palette"), wait_ms);
    QCOMPARE(client_->paletteState().value(QStringLiteral("editorText")).toString(), QStringLiteral("?"));
    query()->forceActiveFocus();
    QTRY_VERIFY_WITH_TIMEOUT(query()->hasActiveFocus(), wait_ms);
    QCOMPARE(state().value(QStringLiteral("heading")).toString(), QStringLiteral("Start with a task"));
    client_->execute(Application::Action::cancel);
  }

  Q_SLOT void replacementRequestsDiscardTheEarlierCommandAndPasteOnlyOnConfirmation() {
    open(QStringLiteral("?fixture:delay"));
    submit();
    QCOMPARE(state().value(QStringLiteral("heading")).toString(), QStringLiteral("Generating a command…"));
    client_->searchPalette(QStringLiteral("?fixture:alternate"));
    QCOMPARE(state().value(QStringLiteral("heading")).toString(), QStringLiteral("Start with a task"));
    submit();
    QTRY_VERIFY_WITH_TIMEOUT(state().value(QStringLiteral("ready")).toBool(), wait_ms);
    const auto command = state().value(QStringLiteral("text")).toString();
    QVERIFY(command.contains(QLatin1StringView("ALTERNATE_REVIEW")));
    QVERIFY(!QFileInfo::exists(marker_));
    query()->forceActiveFocus();
    QTest::keyClick(window_.get(), Qt::Key_Return);
    QTRY_VERIFY_WITH_TIMEOUT(client_->dialog().isEmpty(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(screenText(client_->pane(pane_id_)->screen, ScreenTextLayout::logical).contains(command), wait_ms);
    QVERIFY(!QFileInfo::exists(marker_));
    terminal_->forceActiveFocus();
    QTest::keyClick(window_.get(), Qt::Key_Return);
    const QByteArray expected{"ALTERNATE_REVIEW"};
    QTRY_COMPARE_WITH_TIMEOUT(QFileInfo{marker_}.size(), expected.size(), wait_ms);
    QFile marker{marker_};
    QVERIFY(marker.open(QIODevice::ReadOnly));
    QCOMPARE(marker.readAll(), expected);
    marker.close();
    QVERIFY(marker.remove());
  }

  Q_SLOT void providerFailureAndTimeoutCanRetryWithoutClosingTheComponent() {
    open(QStringLiteral("?fixture:fail"));
    submit();
    QTRY_VERIFY_WITH_TIMEOUT(state().value(QStringLiteral("failed")).toBool(), wait_ms);
    QCOMPARE(state().value(QStringLiteral("message")).toString(), QStringLiteral("The engine could not answer. Try again."));
    client_->searchPalette(QStringLiteral("?fixture:timeout"));
    submit();
    QTRY_VERIFY_WITH_TIMEOUT(state().value(QStringLiteral("failed")).toBool(), wait_ms);
    QCOMPARE(state().value(QStringLiteral("message")).toString(), QStringLiteral("The engine timed out. Try again."));
    QCOMPARE(client_->dialog(), QStringLiteral("palette"));
    client_->searchPalette(QStringLiteral("?fixture:ready"));
    submit();
    QTRY_VERIFY_WITH_TIMEOUT(state().value(QStringLiteral("ready")).toBool(), wait_ms);
    auto const *button = panel_->findChild<QQuickItem *>(QStringLiteral("suggestionSubmit"));
    QVERIFY(button != nullptr);
    QVERIFY(test::waitForSynchronizedFrame(*window_, wait_ms));
    const auto point = button->mapToScene({button->width() / 2, button->height() / 2}).toPoint();
    QTest::mousePress(window_.get(), Qt::LeftButton, Qt::NoModifier, point);
    client_->searchPalette(QStringLiteral("?edited before release"));
    QTest::mouseRelease(window_.get(), Qt::LeftButton, Qt::NoModifier, point);
    QCOMPARE(client_->dialog(), QStringLiteral("palette"));
    QCOMPARE(state().value(QStringLiteral("heading")).toString(), QStringLiteral("Start with a task"));
    QVERIFY(!QFileInfo::exists(marker_));
    client_->execute(Application::Action::cancel);
  }

  Q_SLOT void shortenedPreviewsKeepTheEntirePaste() {
    open(QStringLiteral("?fixture:long"));
    submit();
    QTRY_VERIFY_WITH_TIMEOUT(state().value(QStringLiteral("ready")).toBool(), wait_ms);
    const auto lines = client_->suggestionGeometry().value(QStringLiteral("lines")).toList();
    QVERIFY(!lines.empty() && lines.back().toMap().value(QStringLiteral("shortened")).toBool());
    const auto command = state().value(QStringLiteral("text")).toString();
    submit();
    QTRY_VERIFY_WITH_TIMEOUT(client_->dialog().isEmpty(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(screenText(client_->pane(pane_id_)->screen, ScreenTextLayout::logical).contains(command), wait_ms);
    QVERIFY(!QFileInfo::exists(marker_));
    client_->input(pane_id_, "\x15");
  }

  Q_SLOT void cleanupTestCase() {
    panel_.reset();
    terminal_.reset();
    window_.reset();
    client_.reset();
    runtime_.terminate();
    if (!runtime_.waitForFinished()) {
      runtime_.kill();
      runtime_.waitForFinished();
    }

    QCOMPARE(errors_, QString{});
  }

  void synchronizeSurfaces() {
    if (!client_ || !terminal_ || !panel_) {
      return;
    }

    const auto terminal = client_->windowGeometry().value(QStringLiteral("terminal")).toRectF();
    terminal_->setPosition(terminal.topLeft());
    terminal_->setSize(terminal.size());
    const auto palette = client_->paletteGeometry().value(QStringLiteral("bounds")).toRectF();
    panel_->setPosition(palette.topLeft());
    panel_->setSize(palette.size());
    panel_->setVisible(client_->dialog() == QLatin1StringView("palette"));
    if (client_->dialog().isEmpty()) {
      terminal_->forceActiveFocus();
    }
  }

  [[nodiscard]] QVariantMap state() const {
    return client_->suggestionState();
  }

  [[nodiscard]] NativeFormField *query() const {
    return panel_->findChild<NativeFormField *>(QStringLiteral("commandSearch"));
  }

  void open(const QString &task) {
    client_->execute(Application::Action::suggest_command);
    client_->searchPalette(task);
    QVERIFY(query() != nullptr);
    query()->forceActiveFocus();
  }

  void submit() {
    client_->submitSuggestion(state().value(QStringLiteral("revision")).toString());
  }

  ApplicationAllocator memory_;
  QTemporaryDir directory_{QDir::tempPath() + QStringLiteral("/telar-suggest-XXXXXX")};
  QProcess runtime_;
  std::unique_ptr<QQuickWindow> window_ = std::make_unique<QQuickWindow>();
  QQmlEngine engine_;
  std::unique_ptr<Application> client_;
  std::unique_ptr<TerminalItem> terminal_;
  std::unique_ptr<QQuickItem> panel_;
  QString marker_;
  QString socket_;
  QString errors_;
  std::uint64_t pane_id_ = 0;
};

}

QTEST_MAIN(SuggestionControlsTest)
#include "suggestion_controls_test.moc"
