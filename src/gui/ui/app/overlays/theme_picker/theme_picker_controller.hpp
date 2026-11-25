#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "tbc/view.hpp"
#include "ui/app/chrome/components/surface_command.hpp"
#include "ui/kit/config/configuration_source.hpp"
#include <QByteArray>
#include <QList>
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>
#include <cstddef>

#pragma once

namespace telar::gui::qt {

  // The theme picker over the window: one slice per theme, the configuration's first. The window
  // shows the focused theme while the picker is open; choosing one saves it for every window and
  // runs `client.theme_picker.on_select`, and leaving puts back the theme the window had.
  class ThemePickerController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(ThemePickerController)
    QML_UNCREATABLE("Use the window's theme picker")
    Q_PROPERTY(bool open READ isOpen NOTIFY changed)
    Q_PROPERTY(QVariantList themes READ themes NOTIFY changed)
    Q_PROPERTY(int focus READ focus NOTIFY changed)

  public:
    explicit ThemePickerController(ConfigurationSource& source, QObject* parent = nullptr);
    ~ThemePickerController() override = default;
    ThemePickerController(const ThemePickerController&) = delete;
    ThemePickerController& operator=(const ThemePickerController&) = delete;
    ThemePickerController(ThemePickerController&&) = delete;
    ThemePickerController& operator=(ThemePickerController&&) = delete;

    [[nodiscard]] bool isOpen() const noexcept;
    [[nodiscard]] QVariantList themes() const;
    [[nodiscard]] int focus() const noexcept;

    // Lists the themes with the window's own focused.
    void open();
    // Another dialog took the picker's place: the window shows its theme again.
    void dismiss();

    Q_INVOKABLE void focusTheme(int index);
    Q_INVOKABLE void move(int delta);
    // Focuses the first theme whose name starts with what was typed in the last moment.
    Q_INVOKABLE void type(const QString& text);
    Q_INVOKABLE void choose();
    Q_INVOKABLE void cancel();

  signals:
    void changed();
    void closeRequested();
    void failed(const QString& message);

  private:
    // The configuration's slot leads the list; each theme of the catalog follows it.
    static constexpr int configuration_slot = 0;

    void close();
    void preview();
    void runOnSelect(const QByteArray& name);
    [[nodiscard]] ds::Option<ThemeValues> focusedValues() const;

    ConfigurationSource& source_;
    tbc::val_self<SurfaceCommand> on_select_;
    // The names of the themes, in the order the slices show them after the configuration's.
    QList<QByteArray> names_;
    QVariantList themes_;
    QString typed_;
    qint64 typed_at_ = 0;
    int focus_ = configuration_slot;
    bool open_ = false;
    bool preview_pending_ = false;
  };

}
