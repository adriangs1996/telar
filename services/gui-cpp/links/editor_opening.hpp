#pragma once

#include "link_text.hpp"
#include "memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace telar::gui {

struct EditorSource {
  std::uint64_t pane_id = 0;
  std::uint64_t pane_generation = 0;
  std::uint64_t attachment_generation = 0;
  TabLocation location{};
};

class EditorTarget {
public:
  EditorTarget(std::string_view editor, std::string_view path, std::uint32_t line, std::uint32_t column)
      : line_(line),
        column_(column) {
    DisplayText16<LinkText::maximum_uri_bytes, false>::validate(editor);
    DisplayText16<LinkText::maximum_uri_bytes, false>::validate(path);
    if (editor.starts_with('-') || !path.starts_with('/') || (column != 0 && line == 0)) {
      throw std::invalid_argument{"InvalidEditorTarget"};
    }

    editor_.assign(editor);
    path_.assign(path);
  }

  [[nodiscard]] std::string_view editor() const noexcept {
    return editor_.view();
  }

  [[nodiscard]] std::string_view path() const noexcept {
    return path_.view();
  }

  [[nodiscard]] std::uint32_t line() const noexcept {
    return line_;
  }

  [[nodiscard]] std::uint32_t column() const noexcept {
    return column_;
  }

private:
  runtime::FixedText<LinkText::maximum_uri_bytes> editor_;
  runtime::FixedText<LinkText::maximum_uri_bytes> path_;
  std::uint32_t line_;
  std::uint32_t column_;
};

struct EditorRequest {
  std::uint64_t request_id;
  EditorSource source;
  EditorTarget target;

  [[nodiscard]] OpenEditor message() const noexcept {
    return {.request_id = request_id, .pane_id = source.pane_id, .pane_generation = source.pane_generation, .editor = target.editor(), .path = target.path(), .line = target.line(), .column = target.column()};
  }
};

class EditorOpening {
public:
  void begin(const EditorRequest &request) {
    if (pending_) {
      throw std::runtime_error{"EditorOpenBusy"};
    }

    pending_ = request;
  }

  [[nodiscard]] std::optional<EditorRequest> complete(std::uint64_t request_id) {
    if (!owns(request_id)) {
      return {};
    }

    return std::exchange(pending_, std::nullopt);
  }

  [[nodiscard]] bool owns(std::uint64_t request_id) const noexcept {
    return pending_ && pending_->request_id == request_id;
  }

  void reset() noexcept {
    pending_.reset();
  }

private:
  std::optional<EditorRequest> pending_;
};

}
