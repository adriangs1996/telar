#include "application.hpp"
#include "application/workbench_geometry.hpp"
#include "machines/edit.hpp"
#include "machines/limits.hpp"
#include "machines/machine_token.hpp"
#include "machines/machines.hpp"
#include "presentation/name_prompt_geometry.hpp"
#include "projection.hpp"
#include "text/utf16_prefix.hpp"
#include <QByteArray>
#include <QLatin1StringView>
#include <QQuickWindow>
#include <QString>
#include <QStringView>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringfwd.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <optional>
#include <string_view>

namespace telar::gui::qt {

void Application::showMachinePrompt(std::optional<MachineToken> renamed) {
  if (renamed && (!machines_.contains(*renamed) || renamed->slot == Machines::local_slot)) {
    return;
  }

  machine_prompt_.emplace();
  machine_prompt_->renamed = renamed;
  if (renamed) {
    machine_prompt_->mode = MachinePromptMode::rename;
    machine_prompt_->text = toQString(machines_.row(renamed->slot).label.view());
  }

  showDialog(QStringLiteral("machine"));
  emit machinePromptChanged();
}

std::size_t Application::machinePromptLimit() const noexcept {
  return machine_prompt_ && machine_prompt_->mode == MachinePromptMode::add_destination ? MachineLimits::destination_bytes : MachineLimits::label_bytes;
}

void Application::searchMachinePrompt(const QString &text) {
  if (dialog_ != QLatin1StringView("machine") || !machine_prompt_) {
    return;
  }

  const auto measured = Utf16Prefix::fit(QStringView{text}, machinePromptLimit());
  machine_prompt_->text = text.first(static_cast<qsizetype>(measured.units));
  if (!machine_prompt_->text.isValidUtf16()) {
    machine_prompt_->text = QString::fromUtf8(machine_prompt_->text.toUtf8());
  }

  emit machinePromptChanged();
  if (measured.bytes < measured.requested_bytes) {
    reportMachinePromptLimit(static_cast<qulonglong>(measured.requested_bytes));
  }
}

void Application::reportMachinePromptLimit(qulonglong requested_bytes) {
  if (dialog_ != QLatin1StringView("machine") || !machine_prompt_ || requested_bytes <= machinePromptLimit()) {
    return;
  }

  const auto *const name = machine_prompt_->mode == MachinePromptMode::add_destination ? "prompt.machine_destination_bytes" : "prompt.machine_label_bytes";
  session().reportLimit({.name = name, .noun = "bytes", .value = machinePromptLimit(), .requested = requested_bytes, .route = {}});
  refreshNotifications();
}

void Application::submitMachinePrompt(const QString &revision) {
  if (dialog_ != QLatin1StringView("machine") || !machine_prompt_ || machine_prompt_->text.isEmpty() || revision != QString::number(dialog_generation_)) {
    return;
  }

  if (machine_prompt_->mode == MachinePromptMode::add_label) {
    machine_prompt_->label = machine_prompt_->text;
    machine_prompt_->text.clear();
    machine_prompt_->mode = MachinePromptMode::add_destination;
    ++dialog_generation_;
    emit machinePromptChanged();

    return;
  }

  const auto text = machine_prompt_->text.toUtf8();
  const std::string_view value{text.constData(), static_cast<std::size_t>(text.size())};
  if (machine_prompt_->mode == MachinePromptMode::rename) {
    const auto renamed = machine_prompt_->renamed;
    if (renamed && machines_.contains(*renamed)) {
      static_cast<void>(machine_profiles_.edit({.kind = MachineEditKind::rename, .label = machines_.row(renamed->slot).label.view(), .value = value}));
    }
  } else {
    const auto label = machine_prompt_->label.toUtf8();
    static_cast<void>(machine_profiles_.edit({.kind = MachineEditKind::add, .label = {label.constData(), static_cast<std::size_t>(label.size())}, .value = value}));
  }

  machine_prompt_.reset();
  showDialog({});
}

QVariantMap Application::machinePromptState() const {
  QString title;
  QString text;
  if (machine_prompt_) {
    text = machine_prompt_->text;
    switch (machine_prompt_->mode) {
    case MachinePromptMode::add_label:
      title = QStringLiteral("New machine label");
      break;
    case MachinePromptMode::add_destination:
      title = QStringLiteral("Its SSH destination: user@host or an alias");
      break;
    case MachinePromptMode::rename:
      title = QStringLiteral("Rename machine");
      break;
    }
  }

  return {{QStringLiteral("revision"), QString::number(dialog_generation_)}, {QStringLiteral("title"), title}, {QStringLiteral("editorText"), text}, {QStringLiteral("maximumBytes"), static_cast<qulonglong>(machinePromptLimit())}};
}

QVariantMap Application::machinePromptGeometry() const {
  const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  const auto display = displayMetrics(density);
  const auto &workbench = session().workbenchGeometry();
  const auto geometry = NamePromptGeometry::measure(workbench.cellArea());
  auto bounds = workbench.pixels(geometry.bounds);
  bounds.x += display.geometry.terminal.x;
  bounds.y += display.geometry.terminal.y;
  const auto local = [&](CellRectangle cells) {
    auto area = workbench.pixels(cells);
    area.x += display.geometry.terminal.x - bounds.x;
    area.y += display.geometry.terminal.y - bounds.y;

    return toQRectF(area, density);
  };

  return {{QStringLiteral("bounds"), toQRectF(bounds, density)}, {QStringLiteral("title"), local(geometry.title)}, {QStringLiteral("field"), local(geometry.field)}, {QStringLiteral("footer"), local(geometry.footer)}};
}

}
