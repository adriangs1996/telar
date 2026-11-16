#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "peek_controller.hpp"
#include "application/dependencies.hpp"
#include "ui/app/projection.hpp"
#include "ui/app/utf16_encoding.hpp"
#include <QByteArray>
#include <QLatin1StringView>
#include <QStringList>
#include <QStringView>
#include <variant>

import telar.gui.core.metrics;
import telar.gui.peek.screen;
import telar.gui.presentation.activity_order;
import telar.gui.presentation.notification_stack;
import telar.gui.presentation.suggestion_labels;
import telar.gui.text.bounded_editor;

namespace telar::gui::qt {

  PeekController::PeekController(Store& store, ActivityController& activity, QObject* parent)
      : QObject(parent),
        store_(store),
        activity_(activity) {}

  void PeekController::setDisplay(const DisplayMetrics& display) {
    display_ = display;
    emit changed();
  }

  void PeekController::setWindowGeneration(std::uint64_t generation) noexcept {
    window_generation_ = generation;
  }

  bool PeekController::open(const MachineActivityTarget& target, const QString& identity, std::uint64_t pointer_revision) {
    const auto* agent = std::get_if<MachineActivityTarget::Agent>(&target.owner);
    if (agent == nullptr || !store_.session().openPeek(PeekTarget{.agent = agent->key, .session = agent->session})) {
      return false;
    }

    origin_ = Origin{.target = target, .window = window_generation_};
    editor_.clear();
    activity_.showHover(identity, pointer_revision);

    return true;
  }

  void PeekController::forget() {
    store_.session().closePeek();
    origin_.reset();
    editor_.clear();
  }

  bool PeekController::valid() const {
    if (store_.dialog().kind != Store::Dialog::peek || !origin_ || origin_->window != window_generation_ || !activity_.available(origin_->target)) {
      return false;
    }

    const auto* agent = std::get_if<MachineActivityTarget::Agent>(&origin_->target.owner);
    const auto& target = store_.session().peek().target();

    return agent != nullptr && origin_->target.source.machine.slot == store_.machines().active() && target && *target == PeekTarget{.agent = agent->key, .session = agent->session};
  }

  void PeekController::synchronize() {
    if (store_.dialog().kind != Store::Dialog::peek) {
      return;
    }

    if (!valid()) {
      emit closeRequested();
      return;
    }

    emit changed();
  }

  void PeekController::search(const QString& text) {
    if (!valid()) {
      return;
    }

    const auto measured = Utf16Prefix::fit(QStringView{text}, PeekLimits::message_bytes, utf16Encoding());

    editor_ = text.first(static_cast<qsizetype>(measured.units));
    if (!editor_.isValidUtf16()) {
      editor_ = QString::fromUtf8(editor_.toUtf8());
    }

    emit changed();
    if (measured.bytes < measured.requested_bytes) {
      reportLimit(static_cast<qulonglong>(measured.requested_bytes));
    }
  }

  void PeekController::reportLimit(qulonglong requested_bytes) {
    if (!valid() || requested_bytes <= PeekLimits::message_bytes) {
      return;
    }

    store_.session().reportLimit({.name = "prompt.field_bytes", .noun = "bytes", .value = PeekLimits::message_bytes, .requested = requested_bytes, .route = {}});
    store_.commit();
  }

  void PeekController::submit(const QString& revision) {
    if (revision != QString::number(store_.dialog().generation) || !valid()) {
      return;
    }

    const auto text = editor_.toUtf8();

    store_.begin();
    try {
      if (store_.session().submitPeek({text.constData(), static_cast<std::size_t>(text.size())})) {
        emit closeRequested();
      }
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));

      return;
    }

    store_.commit();
  }

  QVariantMap PeekController::state() const {
    QString title;
    QString facts;
    QStringList lines;

    if (valid()) {
      const auto& session = store_.session();
      if (const auto* agent = session.peekAgent()) {
        const auto* task = AgentOrder::taskRow(session.workspaceList(), *agent);

        title = toQString(PeekLabels::title(*agent, task));
        facts = toQString(PeekLabels::facts(*agent, task).view());
        const auto geometry = PeekGeometry::measure(session.workbenchGeometry().cellArea());
        const auto visible = PeekScreen<Memory>::lastLines(session.peek().text(), geometry.screen.height);

        lines = toQString(visible).split(QLatin1Char('\n'));
      }
    }

    return {{QStringLiteral("revision"), QString::number(store_.dialog().generation)}, {QStringLiteral("title"), title}, {QStringLiteral("facts"), facts}, {QStringLiteral("lines"), lines}, {QStringLiteral("editorText"), editor_}, {QStringLiteral("maximumBytes"), static_cast<qulonglong>(PeekLimits::message_bytes)}};
  }

  QVariantMap PeekController::geometry() const {
    const auto& display = display_;
    const auto density = display.density;
    const auto& workbench = store_.session().workbenchGeometry();
    const auto geometry = PeekGeometry::measure(workbench.cellArea());
    auto bounds = workbench.pixels(geometry.bounds);

    bounds.x += display.geometry.terminal.x;
    bounds.y += display.geometry.terminal.y;
    const auto local = [&](CellRectangle cells) {
      auto area = workbench.pixels(cells);

      area.x += display.geometry.terminal.x - bounds.x;
      area.y += display.geometry.terminal.y - bounds.y;

      return toQRectF(area, density);
    };

    return {{QStringLiteral("bounds"), toQRectF(bounds, density)}, {QStringLiteral("title"), local(geometry.title)}, {QStringLiteral("facts"), local(geometry.facts)}, {QStringLiteral("screen"), local(geometry.screen)}, {QStringLiteral("field"), local(geometry.field)}, {QStringLiteral("footer"), local(geometry.footer)}};
  }

}
