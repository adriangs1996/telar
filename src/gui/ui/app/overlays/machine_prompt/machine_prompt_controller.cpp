#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machine_prompt_controller.hpp"
#include "ui/kit/models/projection.hpp"
#include "ui/kit/text/utf16_encoding.hpp"
#include <QByteArray>
#include <QStringView>
#include <string_view>

import telar.gui.foundation.forms;
import telar.gui.application;

namespace telar::gui::qt {

  MachinePromptController::MachinePromptController(Store& store, MachineProfilesSource& profiles, QObject* parent)
      : QObject(parent),
        store_(store),
        profiles_(profiles) {}

  bool MachinePromptController::isOpen() const noexcept {
    return store_.dialog().kind == Store::Dialog::machine && prompt_.hasValue();
  }

  void MachinePromptController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
    emit changed();
  }

  void MachinePromptController::forget() noexcept {
    prompt_.reset();
  }

  bool MachinePromptController::open(application::machines::MachineToken renamed) {
    if (!store_.machines().contains(renamed) || renamed.slot == application::machines::Machines::local_slot) {
      return false;
    }

    prompt_.emplace(Prompt{.text = toQString(store_.machines().row(renamed.slot).label.view()), .renamed = renamed});
    return true;
  }

  std::size_t MachinePromptController::limit() noexcept {
    return application::machines::MachineLimits::label_bytes;
  }

  void MachinePromptController::search(const QString& text) {
    if (!isOpen()) {
      return;
    }

    const auto measured = Utf16Prefix::fit(QStringView{text}, limit(), utf16Encoding());

    prompt_.getMut().text = text.first(static_cast<qsizetype>(measured.units));
    if (!prompt_->text.isValidUtf16()) {
      prompt_.getMut().text = QString::fromUtf8(prompt_->text.toUtf8());
    }

    emit changed();
    if (measured.bytes < measured.requested_bytes) {
      reportLimit(static_cast<qulonglong>(measured.requested_bytes));
    }
  }

  void MachinePromptController::reportLimit(qulonglong requested_bytes) {
    if (!isOpen() || requested_bytes <= limit()) {
      return;
    }

    application::notifications::reportLimit(store_.sessionMut(), {.name = "prompt.machine_label_bytes", .noun = "bytes", .value = limit(), .requested = requested_bytes, .route = {}});
    store_.commit();
  }

  void MachinePromptController::submit(const QString& revision) {
    if (!isOpen() || prompt_->text.isEmpty() || revision != QString::number(store_.dialog().generation)) {
      return;
    }

    const auto text = prompt_->text.toUtf8();
    const std::string_view value{text.constData(), static_cast<std::size_t>(text.size())};

    if (const auto renamed = prompt_->renamed; store_.machines().contains(renamed)) {
      static_cast<void>(profiles_.edit({.kind = application::machines::MachineEditKind::rename, .label = store_.machines().row(renamed.slot).label.view(), .value = value}));
    }

    prompt_.reset();
    emit closeRequested();
  }

  QVariantMap MachinePromptController::state() const {
    const auto text = prompt_ ? prompt_->text : QString{};
    const auto title = prompt_ ? QStringLiteral("Rename machine") : QString{};

    return {{QStringLiteral("revision"), QString::number(store_.dialog().generation)}, {QStringLiteral("title"), title}, {QStringLiteral("editorText"), text}, {QStringLiteral("maximumBytes"), static_cast<qulonglong>(limit())}};
  }

  QVariantMap MachinePromptController::geometry() const {
    const auto& display = display_;
    const auto density = display.density;
    const auto& workbench = application::workbench::geometry(store_.session());
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
