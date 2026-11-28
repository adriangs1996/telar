module;
#include <QAbstractItemModelTester>
#include <QtTest/QSignalSpy>
#include <QtTest/QTest>

export module telar.gui.qt.testing;

export {
  using ::QAbstractItemModelTester;
  using ::QSignalSpy;

  namespace QTest {
    using ::QTest::Click;
    using ::QTest::currentTestFailed;
    using ::QTest::KeyAction;
    using ::QTest::Press;
    using ::QTest::qExec;
    using ::QTest::qWait;
    using ::QTest::qWaitFor;
    using ::QTest::qWaitForWindowActive;
    using ::QTest::qWaitForWindowExposed;
    using ::QTest::Release;
    using ::QTest::Shortcut;
  }
}

export namespace telar::qt::test {

  void keyClick(QWindow* window, Qt::Key key, Qt::KeyboardModifiers modifier = Qt::NoModifier, int delay = -1);
  void keyPress(QWindow* window, Qt::Key key, Qt::KeyboardModifiers modifier = Qt::NoModifier, int delay = -1);
  void keyRelease(QWindow* window, Qt::Key key, Qt::KeyboardModifiers modifier = Qt::NoModifier, int delay = -1);
  void mouseClick(QWindow* window, Qt::MouseButton button, Qt::KeyboardModifiers state = Qt::NoModifier, QPoint pos = QPoint(), int delay = -1);
  void mousePress(QWindow* window, Qt::MouseButton button, Qt::KeyboardModifiers state = Qt::NoModifier, QPoint pos = QPoint(), int delay = -1);
  void mouseRelease(QWindow* window, Qt::MouseButton button, Qt::KeyboardModifiers state = Qt::NoModifier, QPoint pos = QPoint(), int delay = -1);
  void mouseMove(QWindow* window, QPoint pos = QPoint(), int delay = -1);
  void mouseDClick(QWindow* window, Qt::MouseButton button, Qt::KeyboardModifiers state = Qt::NoModifier, QPoint pos = QPoint(), int delay = -1);

}
