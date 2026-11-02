#include "application.hpp"
#include "application/dependencies.hpp"
#include "application/workbench_geometry.hpp"
#include "machine_activity_target.hpp"
#include "peek/limits.hpp"
#include "peek/screen.hpp"
#include "peek/target.hpp"
#include "presentation/agent_order.hpp"
#include "presentation/peek_geometry.hpp"
#include "presentation/peek_labels.hpp"
#include "projection.hpp"
#include "text/utf16_prefix.hpp"
#include "qt/utf16_encoding.hpp"
#include <QtCore/qstringliteral.h>
#include <QByteArray>
#include <QLatin1StringView>
#include <QQuickWindow>
#include <QString>
#include <QStringList>
#include <QStringView>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qchar.h>
#include <QtCore/qstringfwd.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <cstdint>
#include <string_view>
#include <variant>

namespace telar::gui::qt {

void Application::peekActivity(const QString &identity) {
  applyInteraction([&] {
    selectActivity(identity, true);
  });
}

void Application::openActivityPeek(const MachineActivityTarget &target, const QString &identity, std::uint64_t pointer_revision) {
  const auto *agent = std::get_if<MachineActivityTarget::Agent>(&target.owner);
  if (agent == nullptr || !session().openPeek(PeekTarget{.agent = agent->key, .session = agent->session})) {
    return;
  }

  peek_origin_ = PeekOrigin{.target = target, .window = window_generation_};
  peek_editor_.clear();
  if (pointer_revision == pointer_revision_) {
    activity_hover_ = identity;
    emit activityHoverChanged();
  }

  showDialog(QStringLiteral("peek"));
  emit peekChanged();
}

bool Application::peekOriginValid() const {
  if (dialog_ != QLatin1StringView("peek") || !peek_origin_ || peek_origin_->window != window_generation_ || !activityAvailable(peek_origin_->target)) {
    return false;
  }

  const auto *agent = std::get_if<MachineActivityTarget::Agent>(&peek_origin_->target.owner);
  const auto &target = session().peek().target();

  return agent != nullptr && peek_origin_->target.source.machine.slot == machines_.active() && target && *target == PeekTarget{.agent = agent->key, .session = agent->session};
}

void Application::refreshPeek() {
  if (dialog_ != QLatin1StringView("peek")) {
    return;
  }

  if (!peekOriginValid()) {
    showDialog({});
    return;
  }

  emit peekChanged();
}

void Application::searchPeek(const QString &text) {
  if (!peekOriginValid()) {
    return;
  }

  const auto measured = Utf16Prefix::fit(QStringView{text}, PeekLimits::message_bytes, utf16Encoding());
  peek_editor_ = text.first(static_cast<qsizetype>(measured.units));
  if (!peek_editor_.isValidUtf16()) {
    peek_editor_ = QString::fromUtf8(peek_editor_.toUtf8());
  }

  emit peekChanged();
  if (measured.bytes < measured.requested_bytes) {
    reportPeekLimit(static_cast<qulonglong>(measured.requested_bytes));
  }
}

void Application::reportPeekLimit(qulonglong requested_bytes) {
  if (!peekOriginValid() || requested_bytes <= PeekLimits::message_bytes) {
    return;
  }

  session().reportLimit({.name = "prompt.field_bytes", .noun = "bytes", .value = PeekLimits::message_bytes, .requested = requested_bytes, .route = {}});
  refreshNotifications();
}

void Application::submitPeek(const QString &revision) {
  if (revision != QString::number(dialog_generation_) || !peekOriginValid()) {
    return;
  }

  const auto text = peek_editor_.toUtf8();
  applyInteraction([&] {
    if (session().submitPeek({text.constData(), static_cast<std::size_t>(text.size())})) {
      showDialog({});
    }
  });
}

QVariantMap Application::peekState() const {
  QString title;
  QString facts;
  QStringList lines;
  if (peekOriginValid()) {
    if (const auto *agent = session().peekAgent()) {
      const auto *task = AgentOrder::taskRow(session().workspaceList(), *agent);
      title = toQString(PeekLabels::title(*agent, task));
      facts = toQString(PeekLabels::facts(*agent, task).view());
      const auto geometry = PeekGeometry::measure(session().workbenchGeometry().cellArea());
      const auto visible = PeekScreen<ApplicationAllocator>::lastLines(session().peek().text(), geometry.screen.height);
      lines = toQString(visible).split(QLatin1Char('\n'));
    }
  }

  return {{QStringLiteral("revision"), QString::number(dialog_generation_)}, {QStringLiteral("title"), title}, {QStringLiteral("facts"), facts}, {QStringLiteral("lines"), lines}, {QStringLiteral("editorText"), peek_editor_}, {QStringLiteral("maximumBytes"), static_cast<qulonglong>(PeekLimits::message_bytes)}};
}

QVariantMap Application::peekGeometry() const {
  const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  const auto display = displayMetrics(density);
  const auto &workbench = session().workbenchGeometry();
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
