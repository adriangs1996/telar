#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/store/store.hpp"
#include <QObject>
#include <QtQml/qqmlregistration.h>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <vector>

#pragma once

import telar.gui.application.workspace_replica;
import telar.gui.core.metrics;
import telar.gui.input.copy_mode;
import telar.gui.prompt.line;
import telar.gui.prompt.routing;

namespace telar::gui::qt {

  class PromptEditorItem;

  // telar's command editor in each pane: who has the pane's keyboard, the line the editor holds
  // and what it suggests, and the command block selected from it.
  //
  // It reads the store. The editors that draw a line attach to it, and the window tells it when a
  // pane's line or screen moved, or the configuration changed: it refreshes the editors of that
  // pane directly, since a pane's output reaches here as often as it paints.
  class PromptController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(PromptController)
    QML_UNCREATABLE("Use the window's prompt")

  public:
    explicit PromptController(Store& store, QObject* parent = nullptr);
    ~PromptController() override = default;
    PromptController(const PromptController&) = delete;
    PromptController& operator=(const PromptController&) = delete;
    PromptController(PromptController&&) = delete;
    PromptController& operator=(PromptController&&) = delete;

    [[nodiscard]] prompt::Surface surface(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] bool edits(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] bool hidesTerminalCursor(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] const prompt::Line* line(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] std::string_view suggestion(std::uint64_t pane_id) const noexcept;
    // Whether the pane's shell runs `word`; asks the runtime once and answers pending until then.
    [[nodiscard]] CommandPresence commandPresence(std::uint64_t pane_id, std::string_view word);
    // The command block selected in the pane, by index among its blocks.
    [[nodiscard]] std::optional<std::size_t> selectedBlock(std::uint64_t pane_id) const noexcept;

    // What an editor shows around the line: its pane, the configuration and copy mode.
    [[nodiscard]] const Pane<Memory>* pane(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] const Configuration& configuration() const noexcept;
    [[nodiscard]] const std::optional<CopyState>& copy() const noexcept;

    void attach(PromptEditorItem& editor);
    void detach(PromptEditorItem& editor);
    // The pane's line or screen moved: its editors refresh, keeping their layout if nothing they
    // draw changed.
    void refresh(qulonglong pane_id);
    // The configuration changed: every editor lays its line out again.
    void configure();

  private:
    Store& store_;
    // An editor that detaches leaves its slot empty, so one that attaches or detaches while the
    // others refresh neither moves nor skips them.
    std::vector<PromptEditorItem*> editors_;
  };

}
