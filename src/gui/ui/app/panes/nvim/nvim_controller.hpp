#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "nvim_host.hpp"
#include "tbc/view.hpp"
#include "ui/kit/store/store.hpp"
#include <QByteArray>
#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <string_view>

#pragma once

import telar.gui.foundation.core;
import telar.gui.application;

namespace telar::gui::qt {

  // The editor panes of a window: what their views read from the active session and what they
  // write to it. A view listens for the frames of its own pane.
  class NvimController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(NvimController)
    QML_UNCREATABLE("Use the window's editors")

  public:
    struct Parts {
      Store& store;
      NvimHost& host;
    };

    // Keeps what the parts refer to, region `a`, not the parts themselves.
    explicit NvimController(tbc::holds<const Parts&, tbc::lt::a> parts, QObject* parent = nullptr);
    ~NvimController() override = default;

    NvimController(const NvimController&) = delete;
    NvimController& operator=(const NvimController&) = delete;
    NvimController(NvimController&&) = delete;
    NvimController& operator=(NvimController&&) = delete;

    [[nodiscard]] const application::nvim::Editor* editor(std::uint64_t pane_id) const noexcept {
      return application::nvim::editor(store_.session(), pane_id);
    }

    [[nodiscard]] const application::Pane<Memory>* pane(std::uint64_t pane_id) const noexcept {
      return store_.session().findPane(pane_id);
    }

    [[nodiscard]] const Configuration& configuration() const noexcept {
      return store_.session().configuration;
    }

    [[nodiscard]] NvimHost& host() const noexcept {
      return host_;
    }

    // What the views write to the session. A failure goes up as failed().
    void type(std::uint64_t pane_id, std::string_view keys);
    void paste(std::uint64_t pane_id, const QString& text);
    void point(const application::nvim::NvimMouse& event);
    void focus(std::uint64_t pane_id, bool focused);
    void resize(std::uint64_t pane_id, TerminalSize size);
    void answer(std::uint64_t pane_id, bool accepted, std::uint32_t index, const QString& text);
    void choose(std::uint64_t pane_id, std::uint32_t item, bool accept);
    // The pane's picker: what it lists, the query typed, what is opened from it and where.
    void pick(std::uint64_t pane_id, application::nvim::NvimPickSource source);
    void search(std::uint64_t pane_id, const QString& query);
    void accept(std::uint64_t pane_id, application::nvim::Choice choice);
    void preview(std::uint64_t pane_id, ds::Option<std::size_t> index, application::nvim::PreviewArea area);
    void list(std::uint64_t pane_id, std::span<const std::uint32_t> indices);
    void dismiss(std::uint64_t pane_id);
    // A message of the editor, by its key, went from sight.
    void dismissMessage(std::uint64_t pane_id, std::uint64_t key);

  signals:
    // The pane's editor shows another frame, or asks something else.
    void editorChanged(qulonglong pane_id);
    void configurationChanged();
    void failed(const QString& message);

  private:
    template <typename Request>
    void attempt(Request request);

    tbc::mut_a<Store> store_;
    tbc::mut_a<NvimHost> host_;
  };

}
