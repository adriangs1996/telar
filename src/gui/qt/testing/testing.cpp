module;
#include <QtTest/QTest>

module telar.gui.qt.testing;

namespace telar::qt::test {

  void keyClick(QWindow* window, Qt::Key key, Qt::KeyboardModifiers modifier, int delay) {
    ::QTest::keyClick(window, key, modifier, delay);
  }

  void keyPress(QWindow* window, Qt::Key key, Qt::KeyboardModifiers modifier, int delay) {
    ::QTest::keyPress(window, key, modifier, delay);
  }

  void keyRelease(QWindow* window, Qt::Key key, Qt::KeyboardModifiers modifier, int delay) {
    ::QTest::keyRelease(window, key, modifier, delay);
  }

  void mouseClick(QWindow* window, Qt::MouseButton button, Qt::KeyboardModifiers state, QPoint pos, int delay) {
    ::QTest::mouseClick(window, button, state, pos, delay);
  }

  void mousePress(QWindow* window, Qt::MouseButton button, Qt::KeyboardModifiers state, QPoint pos, int delay) {
    ::QTest::mousePress(window, button, state, pos, delay);
  }

  void mouseRelease(QWindow* window, Qt::MouseButton button, Qt::KeyboardModifiers state, QPoint pos, int delay) {
    ::QTest::mouseRelease(window, button, state, pos, delay);
  }

  void mouseMove(QWindow* window, QPoint pos, int delay) {
    ::QTest::mouseMove(window, pos, delay);
  }

  void mouseDClick(QWindow* window, Qt::MouseButton button, Qt::KeyboardModifiers state, QPoint pos, int delay) {
    ::QTest::mouseDClick(window, button, state, pos, delay);
  }

}
