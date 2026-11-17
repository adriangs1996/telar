// The editor request the runtime has yet to answer. Nothing here is exported: only the feature's
// own units name it, through State.
export module telar.gui.features.terminal.links:opening;

import std;

import :editor;

namespace telar::gui::features::terminal::links {

  // At most one request at a time: a second link waits for the first to open.
  class EditorOpening {
  public:
    void begin(const EditorRequest& request);

    [[nodiscard]] std::optional<EditorRequest> complete(std::uint64_t request_id);

    [[nodiscard]] bool owns(std::uint64_t request_id) const noexcept;

    void reset() noexcept;

  private:
    std::optional<EditorRequest> pending_;
  };

}
