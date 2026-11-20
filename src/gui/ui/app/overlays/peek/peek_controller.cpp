#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "peek_controller.hpp"
#include "ui/kit/models/activity_availability.hpp"
#include "ui/kit/models/projection.hpp"
#include "ui/kit/text/utf16_encoding.hpp"
#include <QByteArray>
#include <QLatin1StringView>
#include <QStringList>
#include <QStringView>
#include <variant>

import telar.gui.application;

namespace telar::gui::qt {

  PeekController::PeekController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {}

  void PeekController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
    emit changed();
  }

  void PeekController::setWindowGeneration(std::uint64_t generation) noexcept {
    window_generation_ = generation;
  }

  bool PeekController::open(const application::machines::MachineActivityTarget& target) {
    const auto* agent = std::get_if<application::machines::MachineActivityTarget::Agent>(&target.owner);
    if (agent == nullptr || !application::peek::open(store_.sessionMut(), application::peek::PeekTarget{.agent = agent->key, .session = agent->session})) {
      return false;
    }

    origin_ = Origin{.target = target, .window = window_generation_};
    editor_.clear();

    return true;
  }

  void PeekController::forget() {
    application::peek::close(store_.sessionMut());
    origin_.reset();
    editor_.clear();
  }

  bool PeekController::valid() const {
    if (store_.dialog().kind != Store::Dialog::peek || !origin_ || origin_->window != window_generation_ || !activityAvailable(store_, origin_->target)) {
      return false;
    }

    const auto* agent = std::get_if<application::machines::MachineActivityTarget::Agent>(&origin_->target.owner);
    const auto& target = application::peek::target(store_.session());

    return agent != nullptr && origin_->target.source.machine.slot == store_.machines().active() && target && *target == application::peek::PeekTarget{.agent = agent->key, .session = agent->session};
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

    const auto measured = Utf16Prefix::fit(QStringView{text}, application::peek::PeekLimits::message_bytes, utf16Encoding());

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
    if (!valid() || requested_bytes <= application::peek::PeekLimits::message_bytes) {
      return;
    }

    application::notifications::reportLimit(store_.sessionMut(), {.name = "prompt.field_bytes", .noun = "bytes", .value = application::peek::PeekLimits::message_bytes, .requested = requested_bytes, .route = {}});
    store_.commit();
  }

  void PeekController::submit(const QString& revision) {
    if (revision != QString::number(store_.dialog().generation) || !valid()) {
      return;
    }

    const auto text = editor_.toUtf8();

    store_.interact(
        [&] {
          if (application::peek::submit(store_.sessionMut(), {text.constData(), static_cast<std::size_t>(text.size())})) {
            emit closeRequested();
          }
        },
        [this](const std::exception& error) {
          emit failed(QString::fromUtf8(error.what()));
        }
    );
  }

  QVariantMap PeekController::state() const {
    QString title;
    QString facts;
    QStringList lines;

    if (valid()) {
      const auto& session = store_.session();
      if (const auto* agent = application::peek::agent(session)) {
        const auto* task = application::activity::AgentOrder::taskRow(session.workspace_list, *agent);

        title = toQString(application::peek::PeekLabels::title(*agent, task));
        facts = toQString(application::peek::PeekLabels::facts(*agent, task).view());
        const auto geometry = application::peek::PeekGeometry::measure(application::workbench::geometry(session).cellArea());
        const auto visible = application::peek::lines(session, geometry.screen.height);

        lines = toQString(visible).split(QLatin1Char('\n'));
      }
    }

    return {{QStringLiteral("revision"), QString::number(store_.dialog().generation)}, {QStringLiteral("title"), title}, {QStringLiteral("facts"), facts}, {QStringLiteral("lines"), lines}, {QStringLiteral("editorText"), editor_}, {QStringLiteral("maximumBytes"), static_cast<qulonglong>(application::peek::PeekLimits::message_bytes)}};
  }

  QVariantMap PeekController::geometry() const {
    const auto& display = display_;
    const auto density = display.density;
    const auto& workbench = application::workbench::geometry(store_.session());
    const auto geometry = application::peek::PeekGeometry::measure(workbench.cellArea());
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
