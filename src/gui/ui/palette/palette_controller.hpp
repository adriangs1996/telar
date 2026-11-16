#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/store/store.hpp"
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <string_view>
#include <variant>

#pragma once

import telar.gui.machines.picker;
import telar.gui.model.replicas;
import telar.gui.palette.navigation_label;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.suggestion_geometry;

namespace telar::gui::qt {

  // A window action a palette row runs, by its value: the window's action enum is declared by the
  // window, which reads this controller.
  struct PaletteAction {
    int value = 0;
  };

  using PaletteTarget = std::variant<NavigationTarget, PaletteAction, MachinePickerTarget>;

  // The command palette: its query, the rows it matches among the active session's contexts, tabs
  // and agents, the window's actions or the machines, which row is selected, and where each is
  // drawn. The command suggestion is one of its modes and shares its query, and the actions
  // palette it was opened from.
  //
  // It reads the store and the display and commands the window pushes. Using a row acts on the
  // session or the window, so the window does it with what this controller answers. It asks the
  // window to show its dialog again when it changes mode in place, and to close it once a
  // suggestion is submitted.
  class PaletteController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(PaletteController)
    QML_UNCREATABLE("Use the window's palette")
    Q_PROPERTY(QVariantMap state READ state NOTIFY changed)
    Q_PROPERTY(QVariantMap geometry READ geometry NOTIFY changed)
    Q_PROPERTY(QVariantMap suggestion READ suggestion NOTIFY changed)
    Q_PROPERTY(QVariantMap suggestionGeometry READ suggestionGeometry NOTIFY changed)

  public:
    struct EditorPosition {
      int anchor = 0;
      int cursor = 0;
      std::uint64_t revision = 0;
    };

    // The actions palette a suggestion was opened from, to return to it as it was.
    struct Parent {
      QString query;
      std::size_t selection = 0;
      EditorPosition editor;
    };

    struct Choice {
      PaletteTarget target;
      std::size_t index = 0;
    };

    explicit PaletteController(Store& store, QObject* parent = nullptr);
    ~PaletteController() override = default;
    PaletteController(const PaletteController&) = delete;
    PaletteController& operator=(const PaletteController&) = delete;
    PaletteController(PaletteController&&) = delete;
    PaletteController& operator=(PaletteController&&) = delete;

    [[nodiscard]] QVariantMap state() const;
    [[nodiscard]] QVariantMap geometry() const;
    [[nodiscard]] QVariantMap suggestion() const;
    [[nodiscard]] QVariantMap suggestionGeometry() const;

    Q_INVOKABLE void search(const QString& text);
    Q_INVOKABLE void move(int delta);
    Q_INVOKABLE void setMode(int mode);
    Q_INVOKABLE void reportQueryLimit(qulonglong requested_bytes);
    // Submits the suggestion's task while the suggestion the view shows is the current one.
    Q_INVOKABLE void submitSuggestion(const QString& revision);

    // Starts the palette in a mode, with an empty query; the window shows its dialog.
    void open(PaletteMode mode);
    // Matches the query again while the palette is open, and notifies when the rows moved.
    void synchronize();
    // Notifies a change of the session the suggestion reads.
    void publish();
    // The dialog closed: no actions palette waits to be returned to.
    void forget() noexcept;
    // The display and the window's actions, as the window measures and binds them.
    void setDisplay(const DisplayMetrics& display);
    void setCommands(QVariantList commands);

    [[nodiscard]] PaletteMode mode() const;
    [[nodiscard]] const QString& query() const noexcept;
    // The row a choice from QML names, while it is the one the palette shows.
    [[nodiscard]] std::optional<Choice> chosen(const QVariantMap& choice) const;
    [[nodiscard]] std::optional<MachinePickerTarget> chosenMachine(const QVariantMap& choice) const;
    // The actions palette as it is, to return to from the suggestion opened from its row.
    [[nodiscard]] Parent parentFor(const QVariantMap& choice, std::size_t index) const;
    void adoptParent(Parent parent);
    // Returns to the actions palette the suggestion was opened from; false when the palette is
    // closed or was not opened from one.
    bool restoreParent();
    // The suggestion's revision, which a submission names.
    [[nodiscard]] QString suggestionRevision() const;
    // How many times the rows were matched again and moved, for tests and probes that check what
    // a change costs.
    [[nodiscard]] std::uint64_t rebuilds() const noexcept;

  signals:
    void changed();
    // The palette changed mode in place: the window shows its dialog again.
    void showRequested();
    void closeRequested();
    void failed(const QString& message);

  private:
    static constexpr std::size_t capacity = WorkspaceReplica<Memory>::maximum_workspaces + GuiSession::maximum_workspace_tabs + AgentReplica<Memory>::capacity;
    using Matches = RankedMatches<PaletteTarget, capacity>;

    [[nodiscard]] bool isOpen() const noexcept;
    bool updateResults();
    bool updateMachineResults(std::string_view query);
    void collectNavigation(Matches& matches, std::string_view query) const;
    [[nodiscard]] QVariantMap record(const PaletteTarget& target, bool queried) const;
    [[nodiscard]] QVariantMap machineRecord(MachinePickerTarget target) const;

    // Runs a user's mutation of the session and commits it to the store.
    template <typename Mutation>
    void interact(Mutation mutate) {
      store_.begin();
      try {
        mutate();
      } catch (const std::exception& error) {
        emit failed(QString::fromUtf8(error.what()));

        return;
      }

      store_.commit();
    }

    Store& store_;
    QString query_;
    std::optional<Parent> parent_;
    EditorPosition editor_restore_;
    QVariantList rows_;
    QVariantList commands_;
    std::array<PaletteTarget, capacity> targets_{};
    std::array<PaletteRowKind, capacity> kinds_{};
    std::size_t selection_ = 0;
    std::uint64_t revision_ = 0;
    std::uint64_t rebuilds_ = 0;
    DisplayMetrics display_{};
  };

}
