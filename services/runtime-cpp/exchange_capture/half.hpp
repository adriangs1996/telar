#pragma once

#include "buffer.hpp"
#include "telar_base/memory/sensitive_text.hpp"
#include "telar_base/text/ascii.hpp"
#include "telar_base/text/fields.hpp"
#include "telar_config/proxy/capture_limits.hpp"
#include "types.hpp"

namespace telar::runtime {

template <Allocator Memory>
class CaptureHalf {
public:
  explicit CaptureHalf(Memory &memory, CaptureQuota &quota, const ProxyCaptureLimits &limits, CaptureStart start)
      : key(start.key), side(start.side), protocol(start.protocol), started_at_ms(start.started_at_ms),
        head(memory, quota, limits.part_bytes), body(memory, quota, limits.part_bytes), maximum_bytes_(std::max(std::size_t{1}, limits.exchange_bytes / 2)) {
    host_.append(start.host);
  }

  bool append(CapturePart part, std::span<const std::uint8_t> input) noexcept {
    auto *selected = select(part);
    if (selected == nullptr) {
      return false;
    }

    const auto part_room = selected->remaining();
    const auto half_room = remaining();
    const auto allowed = std::min({input.size(), part_room, half_room});
    if (allowed != input.size()) {
      if (part_room <= half_room) {
        truncation.part = true;
      } else {
        truncation.exchange = true;
      }
    }

    const auto accepted = selected->append(input.first(allowed));
    if (accepted != allowed) {
      truncation.total = true;
    }
    selected->truncated = selected->truncated || accepted != input.size();
    return accepted == input.size() && !selected->truncated;
  }

  bool append(CapturePart part, std::string_view input) noexcept {
    return append(part, {reinterpret_cast<const std::uint8_t *>(input.data()), input.size()});
  }

  void appendHead(std::string_view bytes) noexcept {
    append(headPart(), bytes);
    if (side == CaptureSide::request) {
      const auto line_end = bytes.find("\r\n");
      if (line_end == std::string_view::npos) {
        return;
      }
      TextFields fields{bytes.substr(0, line_end), " "};
      const auto method = fields.next();
      const auto target = fields.next();
      if (!method || !target) {
        return;
      }
      setMethod(*method);
      setTarget(*target);
    }

    TextFields lines{bytes, "\r\n"};
    lines.next();
    while (const auto line = lines.next()) {
      const auto colon = line->find(':');
      if (colon != std::string_view::npos && asciiEqualIgnoreCase(trimText(line->substr(0, colon), " \t"), "content-encoding")) {
        setEncoding(trimText(line->substr(colon + 1), " \t"));
        return;
      }
    }
  }

  void setMethod(std::string_view value) noexcept { setRouteField(method_, value); }
  void setTarget(std::string_view value) noexcept { setRouteField(target_, value); }

  void setEncoding(std::string_view value) noexcept {
    encoding_.clear();
    encoding_.append(value.substr(0, maximum_encoding_bytes));
    body.truncated = body.truncated || value.size() > maximum_encoding_bytes;
  }

  void finish(CaptureOutcome result, std::int64_t timestamp) noexcept {
    outcome = result;
    finished_at_ms = timestamp;
  }

  CapturePart headPart() const noexcept { return side == CaptureSide::request ? CapturePart::request_head : CapturePart::response_head; }
  CapturePart bodyPart() const noexcept { return side == CaptureSide::request ? CapturePart::request_body : CapturePart::response_body; }
  std::size_t capturedBytes() const noexcept { return head.size() + body.size(); }
  std::size_t remaining() const noexcept { return maximum_bytes_ - capturedBytes(); }
  std::size_t bodyLimit() const noexcept { return maximum_bytes_ - head.size(); }
  std::string_view host() const noexcept { return host_.view(); }
  std::string_view method() const noexcept { return method_.view(); }
  std::string_view target() const noexcept { return target_.view(); }
  std::string_view encoding() const noexcept { return encoding_.view(); }

  static constexpr std::size_t maximum_host_bytes = 255;
  static constexpr std::size_t maximum_method_bytes = 32;
  static constexpr std::size_t maximum_target_bytes = 8 * 1024;
  static constexpr std::size_t maximum_encoding_bytes = 128;
  const CaptureKey key;
  const CaptureSide side;
  const CaptureProtocol protocol;
  const std::int64_t started_at_ms;
  std::int64_t finished_at_ms = 0;
  CaptureOutcome outcome = CaptureOutcome::failed;
  std::uint16_t status_code = 0;
  bool body_decoded = false;
  CaptureTruncation truncation;
  CaptureBuffer<Memory> head;
  CaptureBuffer<Memory> body;

private:
  template <std::size_t Capacity>
  void setRouteField(SensitiveText<Capacity> &field, std::string_view value) noexcept {
    if (value.size() > Capacity) {
      head.truncated = true;
      return;
    }
    field.clear();
    field.append(value);
  }

  CaptureBuffer<Memory> *select(CapturePart part) noexcept {
    switch (part) {
    case CapturePart::request_head:
      return side == CaptureSide::request ? &head : nullptr;
    case CapturePart::request_body:
      return side == CaptureSide::request ? &body : nullptr;
    case CapturePart::response_head:
      return side == CaptureSide::response ? &head : nullptr;
    case CapturePart::response_body:
      return side == CaptureSide::response ? &body : nullptr;
    }
    return nullptr;
  }

  const std::size_t maximum_bytes_;
  SensitiveText<maximum_host_bytes> host_;
  SensitiveText<maximum_method_bytes> method_;
  SensitiveText<maximum_target_bytes> target_;
  SensitiveText<maximum_encoding_bytes> encoding_;
};

}
