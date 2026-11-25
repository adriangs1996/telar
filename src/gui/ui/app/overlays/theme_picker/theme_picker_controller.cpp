#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "theme_picker_controller.hpp"
#include "ui/kit/models/projection.hpp"
#include <QDateTime>
#include <QTimer>
#include <QVariantMap>
#include <algorithm>
#include <chrono>
#include <exception>
#include <string_view>

import telar.gui.application;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::qt {

  namespace {

    // The colors a slice draws its theme's window with.
    QVariantMap sliceColors(const ThemeValues& values) {
      const auto theme = projectTheme(values);
      QVariantList ansi;

      for (std::size_t index = 0; index < TerminalThemeValues::palette_size; ++index) {
        ansi.append(toQColor(theme.palette[index]));
      }

      return {
          {QStringLiteral("background"), toQColor(theme.background)},
          {QStringLiteral("foreground"), toQColor(theme.foreground)},
          {QStringLiteral("panel"), toQColor(theme.chromeColor(PaletteRole::panel_bg))},
          {QStringLiteral("sidebar"), toQColor(theme.chromeColor(PaletteRole::surface_dim))},
          {QStringLiteral("surface"), toQColor(theme.chromeColor(PaletteRole::surface0))},
          {QStringLiteral("border"), toQColor(theme.chromeColor(PaletteRole::surface1))},
          {QStringLiteral("accent"), toQColor(theme.chromeColor(PaletteRole::accent))},
          {QStringLiteral("text"), toQColor(theme.chromeColor(PaletteRole::text))},
          {QStringLiteral("subtext"), toQColor(theme.chromeColor(PaletteRole::subtext0))},
          {QStringLiteral("ansi"), ansi},
      };
    }

    QString label(const application::configuration::ThemeEntry& entry) {
      return toQString(entry.label.view());
    }

  }

  ThemePickerController::ThemePickerController(ConfigurationSource& source, QObject* parent)
      : QObject(parent),
        source_(source) {}

  bool ThemePickerController::isOpen() const noexcept {
    return open_;
  }

  QVariantList ThemePickerController::themes() const {
    return themes_;
  }

  int ThemePickerController::focus() const noexcept {
    return focus_;
  }

  void ThemePickerController::open() {
    const auto& catalog = source_.themePicker().catalog;
    const auto configured = source_.configuredTheme();
    const auto* chosen = source_.chosenTheme();
    const auto entries = catalog.entries();
    // The configuration's slot names the catalog's theme it shows, when it shows one unchanged.
    const auto same = std::ranges::find(entries, configured, &application::configuration::ThemeEntry::values);

    names_.clear();
    themes_.clear();
    themes_.append(QVariantMap{
        {QStringLiteral("name"), QString{}},
        {QStringLiteral("label"), QStringLiteral("Configuration")},
        {QStringLiteral("detail"), same == entries.end() ? QStringLiteral("config.lua") : QStringLiteral("config.lua · ") + label(*same)},
        {QStringLiteral("configuration"), true},
        {QStringLiteral("light"), application::configuration::lightTheme(configured)},
        {QStringLiteral("colors"), sliceColors(configured)},
    });

    focus_ = configuration_slot;
    for (const auto& entry : entries) {
      if (&entry == chosen) {
        focus_ = static_cast<int>(themes_.size());
      }

      names_.append(QByteArray{entry.name.view().data(), static_cast<qsizetype>(entry.name.view().size())});
      themes_.append(QVariantMap{
          {QStringLiteral("name"), toQString(entry.name.view())},
          {QStringLiteral("label"), label(entry)},
          {QStringLiteral("detail"), entry.light ? QStringLiteral("light") : QStringLiteral("dark")},
          {QStringLiteral("configuration"), false},
          {QStringLiteral("light"), entry.light},
          {QStringLiteral("colors"), sliceColors(entry.values)},
      });
    }

    typed_.clear();
    open_ = true;
    emit changed();
  }

  void ThemePickerController::dismiss() {
    if (!open_) {
      return;
    }

    preview_pending_ = false;
    source_.previewTheme(ds::none);
    open_ = false;
    emit changed();
  }

  void ThemePickerController::focusTheme(int index) {
    if (!open_ || index < 0 || index >= themes_.size() || index == focus_) {
      return;
    }

    focus_ = index;
    emit changed();
    preview();
  }

  void ThemePickerController::move(int delta) {
    if (!open_ || themes_.isEmpty()) {
      return;
    }

    const auto count = static_cast<int>(themes_.size());

    focusTheme((((focus_ + delta) % count) + count) % count);
  }

  void ThemePickerController::type(const QString& text) {
    constexpr qint64 typing_pause_ms = 800;

    if (!open_ || text.isEmpty()) {
      return;
    }

    const auto now = QDateTime::currentMSecsSinceEpoch();

    typed_ = now - typed_at_ < typing_pause_ms ? typed_ + text : text;
    typed_at_ = now;
    const auto prefix = typed_.toUtf8();
    const auto found = source_.themePicker().catalog.startingWith({prefix.constData(), static_cast<std::size_t>(prefix.size())});
    if (found) {
      focusTheme(static_cast<int>(*found) + 1);
    }
  }

  // Holding an arrow focuses many themes before the window draws one: it shows the last.
  void ThemePickerController::preview() {
    if (preview_pending_) {
      return;
    }

    preview_pending_ = true;
    QTimer::singleShot(0, this, [this] {
      if (!std::exchange(preview_pending_, false) || !open_) {
        return;
      }

      if (const auto values = focusedValues()) {
        source_.previewTheme(values);
      }
    });
  }

  ds::Option<ThemeValues> ThemePickerController::focusedValues() const {
    if (focus_ == configuration_slot) {
      return source_.configuredTheme();
    }

    const auto& name = names_.at(focus_ - 1);
    const auto* entry = source_.themePicker().catalog.find({name.constData(), static_cast<std::size_t>(name.size())});

    return entry == nullptr ? ds::none : ds::Option{entry->values};
  }

  void ThemePickerController::choose() {
    if (!open_) {
      return;
    }

    const auto name = focus_ == configuration_slot ? QByteArray{} : names_.at(focus_ - 1);

    preview_pending_ = false;
    source_.previewTheme(ds::none);
    try {
      source_.chooseTheme(name.isEmpty() ? ds::none : ds::Option{std::string_view{name.constData(), static_cast<std::size_t>(name.size())}});
    } catch (const std::exception& error) {
      emit failed(QStringLiteral("Theme picker: ") + QString::fromUtf8(error.what()));
    }

    if (!name.isEmpty()) {
      runOnSelect(name);
    }

    close();
  }

  void ThemePickerController::cancel() {
    dismiss();
    emit closeRequested();
  }

  void ThemePickerController::close() {
    open_ = false;
    emit changed();
    emit closeRequested();
  }

  void ThemePickerController::runOnSelect(const QByteArray& name) {
    const auto& command = source_.themePicker().on_select;
    if (command.empty()) {
      return;
    }

    if (on_select_.active()) {
      emit failed(QStringLiteral("Theme picker: the previous on_select command is still running"));
      return;
    }

    SurfaceCommandRequest request;

    command.each({name.constData(), static_cast<std::size_t>(name.size())}, [&](std::string_view argument) {
      request.arguments.append(QByteArray{argument.data(), static_cast<qsizetype>(argument.size())});
    });

    request.timeout = std::chrono::milliseconds{command.timeoutMs()};
    request.output = SurfaceOutputUse::ignored;
    on_select_.start(request, [this](const SurfaceCommandResult& result) {
      if (result.failure) {
        emit failed(result.failure == SurfaceCommandFailure::timeout ? QStringLiteral("Theme picker: on_select timed out") : QStringLiteral("Theme picker: on_select failed"));
      }
    });
  }

}
