#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machine_profiles_source.hpp"
#include "ui/foundation/store/store.hpp"
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstddef>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  // The prompt that adds a machine, its label and then its SSH destination, or renames one.
  //
  // It reads the store and the display the window pushes, and writes the machine profiles. The
  // window opens the prompt; submitting its last step asks it to close.
  class MachinePromptController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(MachinePromptController)
    QML_UNCREATABLE("Use the window's machine prompt")
    Q_PROPERTY(QVariantMap state READ state NOTIFY changed)
    Q_PROPERTY(QVariantMap geometry READ geometry NOTIFY changed)

  public:
    MachinePromptController(Store& store, MachineProfilesSource& profiles, QObject* parent = nullptr);
    ~MachinePromptController() override = default;
    MachinePromptController(const MachinePromptController&) = delete;
    MachinePromptController& operator=(const MachinePromptController&) = delete;
    MachinePromptController(MachinePromptController&&) = delete;
    MachinePromptController& operator=(MachinePromptController&&) = delete;

    [[nodiscard]] QVariantMap state() const;
    [[nodiscard]] QVariantMap geometry() const;
    Q_INVOKABLE void search(const QString& text);
    Q_INVOKABLE void submit(const QString& revision);
    Q_INVOKABLE void reportLimit(qulonglong requested_bytes);

    // Starts adding a machine, or renaming one; false when the machine cannot be renamed.
    bool open(ds::Option<application::machines::MachineToken> renamed);
    // The dialog closed: nothing typed belongs to the next prompt.
    void forget() noexcept;
    void setDisplay(const application::window::DisplayMetrics& display);

  signals:
    void changed();
    void closeRequested();

  private:
    enum class Mode : std::uint8_t {
      add_label,
      add_destination,
      rename,
    };

    struct Prompt {
      Mode mode = Mode::add_label;
      QString text;
      QString label;
      ds::Option<application::machines::MachineToken> renamed;
    };

    [[nodiscard]] bool isOpen() const noexcept;
    [[nodiscard]] std::size_t limit() const noexcept;

    Store& store_;
    MachineProfilesSource& profiles_;
    ds::Option<Prompt> prompt_;
    application::window::DisplayMetrics display_{};
  };

}
