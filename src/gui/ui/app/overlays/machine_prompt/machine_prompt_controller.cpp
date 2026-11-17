#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machine_prompt_controller.hpp"
#include "ui/foundation/models/projection.hpp"
#include "ui/foundation/text/utf16_encoding.hpp"
#include <QByteArray>
#include <QStringView>
#include <string_view>

import telar.gui.machines.profile_store;
import telar.gui.foundation.forms;
import telar.gui.application;

namespace telar::gui::qt {

  MachinePromptController::MachinePromptController(Store& store, MachineProfilesSource& profiles, QObject* parent)
      : QObject(parent),
        store_(store),
        profiles_(profiles) {}

  bool MachinePromptController::isOpen() const noexcept {
    return store_.dialog().kind == Store::Dialog::machine && prompt_.has_value();
  }

  void MachinePromptController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
    emit changed();
  }

  void MachinePromptController::forget() noexcept {
    prompt_.reset();
  }

  bool MachinePromptController::open(std::optional<MachineToken> renamed) {
    if (renamed && (!store_.machines().contains(*renamed) || renamed->slot == Machines::local_slot)) {
      return false;
    }

    prompt_.emplace();
    prompt_->renamed = renamed;
    if (renamed) {
      prompt_->mode = Mode::rename;
      prompt_->text = toQString(store_.machines().row(renamed->slot).label.view());
    }

    return true;
  }

  std::size_t MachinePromptController::limit() const noexcept {
    return prompt_ && prompt_->mode == Mode::add_destination ? MachineLimits::destination_bytes : MachineLimits::label_bytes;
  }

  void MachinePromptController::search(const QString& text) {
    if (!isOpen()) {
      return;
    }

    const auto measured = Utf16Prefix::fit(QStringView{text}, limit(), utf16Encoding());

    prompt_->text = text.first(static_cast<qsizetype>(measured.units));
    if (!prompt_->text.isValidUtf16()) {
      prompt_->text = QString::fromUtf8(prompt_->text.toUtf8());
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

    const auto* const name = prompt_->mode == Mode::add_destination ? "prompt.machine_destination_bytes" : "prompt.machine_label_bytes";

    store_.session().reportLimit({.name = name, .noun = "bytes", .value = limit(), .requested = requested_bytes, .route = {}});
    store_.commit();
  }

  void MachinePromptController::submit(const QString& revision) {
    if (!isOpen() || prompt_->text.isEmpty() || revision != QString::number(store_.dialog().generation)) {
      return;
    }

    if (prompt_->mode == Mode::add_label) {
      prompt_->label = prompt_->text;
      prompt_->text.clear();
      prompt_->mode = Mode::add_destination;
      store_.advanceDialog();
      emit changed();

      return;
    }

    const auto text = prompt_->text.toUtf8();
    const std::string_view value{text.constData(), static_cast<std::size_t>(text.size())};

    if (prompt_->mode == Mode::rename) {
      const auto renamed = prompt_->renamed;
      if (renamed && store_.machines().contains(*renamed)) {
        static_cast<void>(profiles_.edit({.kind = MachineEditKind::rename, .label = store_.machines().row(renamed->slot).label.view(), .value = value}));
      }
    } else {
      const auto label = prompt_->label.toUtf8();

      static_cast<void>(profiles_.edit({.kind = MachineEditKind::add, .label = {label.constData(), static_cast<std::size_t>(label.size())}, .value = value}));
    }

    prompt_.reset();
    emit closeRequested();
  }

  QVariantMap MachinePromptController::state() const {
    QString title;
    QString text;

    if (prompt_) {
      text = prompt_->text;
      switch (prompt_->mode) {
      case Mode::add_label:
        title = QStringLiteral("New machine label");
        break;
      case Mode::add_destination:
        title = QStringLiteral("Its SSH destination: user@host or an alias");
        break;
      case Mode::rename:
        title = QStringLiteral("Rename machine");
        break;
      }
    }

    return {{QStringLiteral("revision"), QString::number(store_.dialog().generation)}, {QStringLiteral("title"), title}, {QStringLiteral("editorText"), text}, {QStringLiteral("maximumBytes"), static_cast<qulonglong>(limit())}};
  }

  QVariantMap MachinePromptController::geometry() const {
    const auto& display = display_;
    const auto density = display.density;
    const auto& workbench = store_.session().workbenchGeometry();
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
