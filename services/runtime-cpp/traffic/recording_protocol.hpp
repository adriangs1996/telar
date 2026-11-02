#pragma once

#include "protocol.hpp"

namespace telar::runtime::traffic::recording {

struct Limits {
  static constexpr std::size_t sessions = 4;
  static constexpr std::size_t session_bytes = 64 * 1024 * 1024;
  static constexpr std::size_t total_bytes = 128 * 1024 * 1024;
  static constexpr std::size_t events = 4096;
  static constexpr std::uint32_t age_ms = 60 * 60 * 1000;
  static constexpr std::size_t page_bytes = 512 * 1024;
  static constexpr std::uint32_t page_events = 128;
};

enum class Operation : Byte { start, query, stop, erase, pcapng, list };
enum class Format : Byte { events, pcapng, list };

struct Request {
  Operation operation = Operation::query;
  std::uint64_t id = 0;
  std::uint64_t cursor = 0;
  std::uint64_t max_bytes = 8 * 1024 * 1024;
  std::uint32_t max_events = 4096;
  std::uint32_t max_age_ms = 60000;
  std::uint32_t limit = 64;
  Selection selection = Selection::all;
  std::string_view filter;
  std::string_view host;
};

struct Page {
  std::uint64_t id = 0;
  bool active = false;
  bool gap = false;
  Format format = Format::events;
  std::uint64_t oldest = 1;
  std::uint64_t next = 1;
  std::uint64_t end = 1;
  std::uint64_t evicted = 0;
  std::uint64_t dropped = 0;
  std::uint64_t contention_drops = 0;
  std::uint64_t bytes = 0;
  std::uint32_t count = 0;
  std::span<const Byte> rows;
};

class Protocol {
public:
  static constexpr std::size_t page_header_bytes = 8 * sizeof(std::uint64_t) + 3 * sizeof(Byte) + sizeof(std::uint32_t);

  static void write(plugins::FrameWriter &writer, const Request &request) {
    validate(request);
    writer.tag(request.operation);
    writer.integer(request.id);
    writer.integer(request.cursor);
    writer.integer(request.max_bytes);
    writer.integer(request.max_events);
    writer.integer(request.max_age_ms);
    writer.integer(request.limit);
    writer.tag(request.selection);
    writer.text(request.filter);
    writer.text(request.host);
  }

  static Request read(plugins::FrameReader &reader) {
    Request request;
    request.operation = reader.tag(Operation::list);
    request.id = reader.integer<std::uint64_t>();
    request.cursor = reader.integer<std::uint64_t>();
    request.max_bytes = reader.integer<std::uint64_t>();
    request.max_events = reader.integer<std::uint32_t>();
    request.max_age_ms = reader.integer<std::uint32_t>();
    request.limit = reader.integer<std::uint32_t>();
    request.selection = reader.tag(Selection::all);
    request.filter = reader.text();
    request.host = reader.text();
    validate(request);
    return request;
  }

  static void header(plugins::FrameWriter &writer, const Page &page) {
    writer.integer(page.id);
    writer.boolean(page.active);
    writer.boolean(page.gap);
    writer.tag(page.format);
    writer.integer(page.oldest);
    writer.integer(page.next);
    writer.integer(page.end);
    writer.integer(page.evicted);
    writer.integer(page.dropped);
    writer.integer(page.contention_drops);
    writer.integer(page.bytes);
    writer.integer(page.count);
  }

  static Page page(std::span<const Byte> input) {
    if (input.size() > Limits::page_bytes || input.size() < page_header_bytes) { throw EncodingError{"Invalid recording page size"}; }
    plugins::FrameReader reader{input.first(page_header_bytes)};
    Page page;
    page.id = reader.integer<std::uint64_t>();
    page.active = reader.boolean();
    page.gap = reader.boolean();
    page.format = reader.tag(Format::list);
    page.oldest = reader.integer<std::uint64_t>();
    page.next = reader.integer<std::uint64_t>();
    page.end = reader.integer<std::uint64_t>();
    page.evicted = reader.integer<std::uint64_t>();
    page.dropped = reader.integer<std::uint64_t>();
    page.contention_drops = reader.integer<std::uint64_t>();
    page.bytes = reader.integer<std::uint64_t>();
    page.count = reader.integer<std::uint32_t>();
    reader.finish();
    if (page.count > Limits::page_events || page.next > page.end || page.oldest > page.end) { throw EncodingError{"Invalid recording cursor"}; }
    page.rows = input.subspan(page_header_bytes);
    return page;
  }

private:
  static void validate(const Request &request) {
    const auto selection = static_cast<Byte>(request.selection);
    const bool no_identity = request.operation == Operation::start || request.operation == Operation::list;
    if (request.max_bytes == 0 || request.max_bytes > Limits::session_bytes || request.max_events == 0 || request.max_events > Limits::events || request.max_age_ms == 0 || request.max_age_ms > Limits::age_ms || request.limit == 0 || request.limit > Limits::page_events || selection == 0 || selection > static_cast<Byte>(Selection::all) || request.filter.size() > traffic::Limits::filter_bytes || request.filter.contains('\0') || request.host.size() > 255 || request.host.contains('\0') || (no_identity ? request.id != 0 : request.id == 0)) {
      throw EncodingError{"Invalid recording request"};
    }
    if (request.operation != Operation::start && !request.filter.empty()) { throw EncodingError{"A recording filter is set at creation"}; }
  }
};

}
