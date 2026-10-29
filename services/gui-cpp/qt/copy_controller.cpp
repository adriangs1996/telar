#include "application.hpp"
#include "input/binding.hpp"
#include "input/copy_pointer.hpp"
#include "key_adapter.hpp"
#include "terminal/copy_grid.hpp"
#include "terminal/copy_state.hpp"
#include <QtCore/qbytearrayview.h>
#include <QtCore/qobject.h>
#include <QtCore/qstring.h>
#include <QtCore/qtmetamacros.h>
#include <QtGui/qevent.h>
#include <cstdint>
#include <exception>
#include <optional>

namespace telar::gui::qt {

bool Application::copyModeActive() const noexcept {
  return session_.copyMode().active();
}

const std::optional<CopyState> &Application::copyState() const noexcept {
  return session_.copyMode().state();
}

bool Application::handleCopyKey(std::uint64_t pane_id, const QKeyEvent &event) {
  const auto &copy = copyState();
  if (!copy || copy->pointer || !dialog_.isEmpty() || copy->pane_id != pane_id) {
    return false;
  }

  const auto semantic = NativeKeyAdapter::terminalKey(event);
  if (!semantic || semantic->has(KeyChord::Modifier::super)) {
    return true;
  }

  try {
    const auto effect = session_.copyKey(*semantic);
    if (effect.search) {
      showDialog(QStringLiteral("copy-search"));
    }

    if (effect.open_link && copyState()) {
      openCopyLink(pane_id, copyState()->cursor);
    }

    emit terminalChanged(pane_id);
    emit stateChanged();
  } catch (const std::exception &error) {
    fail(error);
  }

  return true;
}

void Application::publishCopyChange(std::uint64_t previous_pane) {
  const auto &copy = copyState();
  if (previous_pane != 0) {
    emit terminalChanged(previous_pane);
  }

  if (copy && copy->pane_id != previous_pane) {
    emit terminalChanged(copy->pane_id);
  }

  emit stateChanged();
}

void Application::leaveKeyboardCopyMode() {
  const auto &copy = copyState();
  if (copy && !copy->pointer) {
    const auto pane_id = copy->pane_id;
    session_.leaveCopyMode();
    publishCopyChange(pane_id);
  }
}

bool Application::beginSelection(std::uint64_t pane_id, CopyPoint local) {
  if (!dialog_.isEmpty()) {
    return false;
  }

  key_bindings_.cancelSequence();
  const auto &copy = copyState();
  const auto previous = copy ? copy->pane_id : 0;
  const auto began = session_.beginSelection({.pane_id = pane_id, .position = local, .now_ns = key_bindings_.nowNanoseconds()});
  if (began) {
    publishCopyChange(previous);
  }

  return began;
}

bool Application::handleCopyPointer(const CopyPointerInput &input) {
  const auto owner = session_.copyMode().pointerOwner();
  if (!dialog_.isEmpty() && (!owner || !owner->dragging)) {
    return true;
  }

  if (input.kind == CopyPointerKind::press || input.kind == CopyPointerKind::wheel) {
    key_bindings_.cancelSequence();
  }

  const auto &copy = copyState();
  const auto previous = copy ? copy->pane_id : 0;
  const auto revision = session_.copyMode().revision();
  try {
    const auto outcome = session_.pointer(input);
    if (session_.copyMode().revision() != revision) {
      publishCopyChange(previous);
    }

    return outcome != CopyPointerDecision::Outcome::unowned;
  } catch (const std::exception &error) {
    fail(error);

    return true;
  }
}

void Application::copySelection(std::uint64_t pane_id) {
  try {
    static_cast<void>(session_.copySelection(pane_id));
  } catch (const std::exception &error) {
    fail(error);
  }
}

}
