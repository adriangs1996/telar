#include "baseline-reader.hpp"
#include "candidate-namespaced.hpp"
#include "oracle-before.hpp"
#include <iostream>
#include <random>
#include <typeinfo>
#include <vector>

using namespace telar;
using namespace telar::gui;
static std::uint64_t checks, errors, digest = 1469598103934665603ULL;

template <typename ScreenType>
std::vector<Byte> state(const ScreenType &screen) {
  std::vector<Byte> bytes;
  auto scalar = [&](auto value) {
    const auto *begin = reinterpret_cast<const Byte *>(&value);
    bytes.insert(bytes.end(), begin, begin + sizeof(value));
  };
  auto text = [&](std::string_view value) {
    scalar(value.size());
    bytes.insert(bytes.end(), value.begin(), value.end());
  };
  scalar(screen.paneId());
  scalar(screen.frameId());
  scalar(screen.revision());
  scalar(screen.columns());
  scalar(screen.rows());
  scalar(screen.pointerShape());
  scalar(screen.metadataStatus());
  const auto &cursor = screen.cursor();
  scalar(cursor.visible);
  scalar(cursor.x);
  scalar(cursor.y);
  scalar(cursor.shape);
  scalar(cursor.blink);
  const auto &mouse = screen.mouse();
  scalar(mouse.tracking);
  scalar(mouse.sgr);
  scalar(mouse.pixels);
  const auto &modes = screen.modes();
  scalar(modes.cursor_keys);
  scalar(modes.keypad_keys);
  scalar(modes.bracketed_paste);
  scalar(modes.paste_events);
  scalar(modes.focus_events);
  scalar(modes.alternate_scroll);
  scalar(modes.alternate_screen);
  scalar(modes.kitty_keyboard_flags);
  scalar(modes.modify_other_keys_2);
  scalar(screen.scroll().total_rows);
  scalar(screen.scroll().offset);
  for (std::size_t row = 0; row <= screen.rows(); ++row) {
    scalar(screen.rowRevision(row));
    scalar(screen.rowFlags(row));
    scalar(screen.row(row).size());
  }
  scalar(screen.cells().size());
  for (const auto &cell : screen.cells()) {
    scalar(cell.width);
    scalar(cell.length);
    scalar(cell.style.flags);
    for (const auto &color : {cell.style.foreground, cell.style.background, cell.style.underline_color}) {
      scalar(color.kind);
      for (const auto channel : color.channels) {
        scalar(channel);
      }
    }
    for (const auto byte : cell.text) {
      scalar(byte);
    }
  }
  for (std::size_t position = 0; position <= screen.cells().size(); ++position) {
    text(screen.linkAt(position));
  }
  for (const auto &run : screen.linkRuns()) {
    scalar(run.start);
    scalar(run.len);
    scalar(run.link_index);
  }
  return bytes;
}

struct Fixture {
  PaneFrame frame;
  std::vector<Byte> flags;
  std::vector<FrameSpan> spans;
  std::vector<std::vector<Byte>> encoded;
  std::array<Byte, 9> uri{'h', 't', 't', 'p', 's', ':', '/', '/', 'x'};
  std::array<MetadataLink, 1> links{{{.offset = 0, .len = 9}}};
  std::array<MetadataRun, 1> runs{{{.start = 0, .len = 1, .link_index = 0}}};

  Fixture(std::uint16_t columns, std::uint16_t rows, std::uint64_t pane, std::uint64_t id, std::uint64_t base)
      : flags(rows) {
    frame.pane_id = pane;
    frame.frame_id = id;
    frame.base_frame_id = base;
    frame.cols = columns;
    frame.rows = rows;
    frame.scroll.total_rows = rows + 7;
    frame.scroll.offset = id % 8;
    frame.cursor = {.visible = true, .x = static_cast<std::uint16_t>(id % columns), .y = static_cast<std::uint16_t>(id % rows), .shape = CursorShape::bar, .blink = bool(id % 2)};
    frame.mouse = {.tracking = MouseTracking::any, .sgr = true, .pixels = bool(id % 2)};
    frame.input_modes.bracketed_paste = id % 2;
    frame.input_modes.focus_events = true;
    frame.pointer_shape = PointerShape::pointer;
    if (base == 0 || id % 3 == 0) {
      frame.text_metadata = TextMetadata{.row_flags = flags, .links = links, .runs = runs, .uris = uri};
    }
  }

  void range(std::uint32_t start, std::uint32_t count, unsigned seed) {
    static constexpr std::array<std::string_view, 5> texts{"x", "é", "界", "é", "1234567890123456"};
    std::vector<Cell> cells(count);
    for (std::size_t index = 0; index < count; ++index) {
      auto &cell = cells[index];
      const auto choice = (index + seed) % 7;
      cell.width = choice == 0 ? CellWidth::continuation : choice == 1 ? CellWidth::wide
                                                                       : CellWidth::single;
      cell.text = cell.width == CellWidth::continuation ? std::span<const Byte>{} : byteView(texts[(index + seed) % texts.size()]);
      cell.style.flags = static_cast<std::uint16_t>((index + seed) % 256);
      cell.style.foreground = {.kind = CellColor::Kind::indexed, .channels = {static_cast<Byte>(index + seed), 0, 0}};
    }
    encoded.emplace_back(CellRunCodec::encodedSize(cells));
    CellRunCodec::encode(cells, encoded.back());
    spans.push_back({.start = start, .count = count, .cells = encoded.back()});
  }

  void ready() {
    for (std::size_t i = 0; i < spans.size(); ++i) {
      spans[i].cells = encoded[i];
    }
    frame.spans = spans;
  }
};

template <typename ScreenType>
std::string apply(ScreenType &screen, const PaneFrame &frame) {
  try {
    return std::to_string(static_cast<unsigned>(screen.apply(frame)));
  } catch (const std::exception &error) {
    return std::string{"error:"} + typeid(error).name() + ':' + error.what();
  }
}

static std::uint64_t reader_checks = 0;

template <typename Reader>
std::string validateReader(std::span<const Byte> bytes, unsigned count, unsigned prefix) {
  Reader reader{bytes, count};
  try {
    for (unsigned i = 0; i < prefix; ++i) {
      if (!reader.next()) {
        return "unexpected end";
      }
    }
    if constexpr (requires { reader.validateRemaining(); }) {
      reader.validateRemaining();
    } else {
      while (reader.next()) {
      }
    }
    return reader.next() ? "unexpected remaining cell" : "complete";
  } catch (const std::exception &error) {
    return std::string{"error:"} + typeid(error).name() + ':' + error.what();
  }
}

void readerEquivalence() {
  for (unsigned count = 1; count <= 32; ++count) {
    Fixture fixture{static_cast<std::uint16_t>(count), 1, 1, 1, 0};
    fixture.range(0, count, count);
    const auto original = fixture.encoded.front();
    std::vector<std::vector<Byte>> variants{original};
    auto shortened = original;
    shortened.pop_back();
    variants.push_back(shortened);
    auto trailing = original;
    trailing.push_back(0);
    variants.push_back(trailing);
    for (std::size_t offset = 0; offset < original.size(); offset += 3) {
      auto changed = original;
      changed[offset] ^= 0xff;
      variants.push_back(std::move(changed));
    }
    for (const auto &bytes : variants) {
      for (unsigned prefix : {0u, count / 2, count}) {
        const auto a = validateReader<BaselineCellReader>(bytes, count, prefix);
        const auto b = validateReader<CellReader>(bytes, count, prefix);
        if (a != b) {
          throw std::runtime_error{"Validation-only reader mismatch"};
        }
        ++reader_checks;
      }
    }
  }
}

struct FaultAllocator {
  SystemAllocator upstream;
  std::optional<unsigned> remaining;
  unsigned attempts = 0;

  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    ++attempts;
    if (remaining) {
      if (*remaining == 0) {
        return nullptr;
      }

      --*remaining;
    }

    return upstream.allocate(size, alignment);
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    upstream.deallocate(pointer, size, alignment);
  }

  void failAfter(unsigned allocations) noexcept {
    remaining = allocations;
    attempts = 0;
  }
};

enum class AllocationCase { initial, resize, metadata };
static unsigned allocation_cases, allocation_failures, allocation_free_recoveries;

void allocationEquivalence() {
  constexpr std::size_t budget = 1024 * 1024;
  constexpr unsigned reservation_boundaries = 6;
  constexpr unsigned metadata_links = 8;
  constexpr unsigned uri_bytes = 2;
  for (const auto mode : {AllocationCase::initial, AllocationCase::resize, AllocationCase::metadata}) {
    for (unsigned boundary = 0; boundary <= reservation_boundaries; ++boundary) {
      FaultAllocator upstreamA, upstreamB;
      BudgetAllocator memoryA{upstreamA, budget}, memoryB{upstreamB, budget};
      Screen a{memoryA};
      candidate::Screen b{memoryB};
      auto compare = [&](Fixture &fixture) {
        fixture.ready();
        const auto beforeA = state(a), beforeB = state(b);
        const auto resultA = apply(a, fixture.frame), resultB = apply(b, fixture.frame);
        if (resultA != resultB || state(a) != state(b) || memoryA.liveBytes() != memoryB.liveBytes() || memoryA.allocations() != memoryB.allocations() || memoryA.failures() != memoryB.failures() || upstreamA.attempts != upstreamB.attempts) {
          throw std::runtime_error{"Allocation-failure differential mismatch"};
        }

        const bool failed = resultA.starts_with("error:");
        if (failed && (state(a) != beforeA || state(b) != beforeB)) {
          throw std::runtime_error{"Allocation failure mutated screen"};
        }

        return failed;
      };

      Fixture initial{4, 3, 1, 1, 0};
      initial.range(0, 12, boundary);
      if (mode != AllocationCase::initial && compare(initial)) {
        throw std::runtime_error{"Initial allocation setup failed"};
      }

      Fixture resized{9, 8, 1, 2, 0};
      resized.range(0, 72, boundary);
      Fixture metadata{4, 3, 1, 2, 1};
      std::array<MetadataLink, metadata_links> links;
      std::array<MetadataRun, metadata_links> runs;
      std::array<Byte, metadata_links * uri_bytes> uris;
      for (unsigned index = 0; index < metadata_links; ++index) {
        links[index] = {.offset = index * uri_bytes, .len = uri_bytes};
        runs[index] = {.start = index, .len = 1, .link_index = static_cast<std::uint16_t>(index)};
        uris[index * uri_bytes] = static_cast<Byte>('a' + index);
        uris[index * uri_bytes + 1] = static_cast<Byte>('A' + index);
      }

      metadata.frame.text_metadata = TextMetadata{.row_flags = metadata.flags, .links = links, .runs = runs, .uris = uris};
      auto &target = mode == AllocationCase::initial ? initial : mode == AllocationCase::resize ? resized : metadata;
      upstreamA.failAfter(boundary);
      upstreamB.failAfter(boundary);
      const bool failed = compare(target);
      ++allocation_cases;
      allocation_failures += failed;

      if (mode != AllocationCase::initial && failed) {
        Fixture delta{a.columns(), a.rows(), 1, a.frameId() + 1, a.frameId()};
        delta.frame.text_metadata.reset();
        delta.range(0, 1, boundary);
        upstreamA.failAfter(0);
        upstreamB.failAfter(0);
        if (compare(delta) || upstreamA.attempts != 0 || upstreamB.attempts != 0) {
          throw std::runtime_error{"Same-grid recovery unexpectedly allocated"};
        }

        ++allocation_free_recoveries;
      }

      upstreamA.remaining.reset();
      upstreamB.remaining.reset();
      target.frame.frame_id = a.frameId() + 1;
      target.frame.base_frame_id = mode == AllocationCase::metadata ? a.frameId() : 0;
      if (compare(target)) {
        throw std::runtime_error{"Allocation recovery failed"};
      }
    }
  }

  if (allocation_failures == 0 || allocation_free_recoveries == 0) {
    throw std::runtime_error{"Missing allocation failure coverage"};
  }
}

int exercise() {
  readerEquivalence();
  allocationEquivalence();
  SystemAllocator upstream;
  constexpr std::size_t budget = 32 * 1024 * 1024;
  BudgetAllocator memoryA{upstream, budget}, memoryB{upstream, budget};
  Screen a{memoryA};
  candidate::Screen b{memoryB};
  auto compare = [&](Fixture &fixture) {
    fixture.ready();
    const auto beforeA = state(a), beforeB = state(b);
    const auto resultA = apply(a, fixture.frame), resultB = apply(b, fixture.frame);
    const auto afterA = state(a), afterB = state(b);
    if (resultA != resultB || afterA != afterB || memoryA.liveBytes() != memoryB.liveBytes() || memoryA.allocations() != memoryB.allocations()) {
      throw std::runtime_error{"Screen differential mismatch"};
    }
    if (resultA.starts_with("error:")) {
      ++errors;
      if (afterA != beforeA || afterB != beforeB) {
        throw std::runtime_error{"Failed frame mutated screen"};
      }
    }
    for (auto byte : afterA) {
      digest ^= byte;
      digest *= 1099511628211ULL;
    }
    ++checks;
  };
  std::mt19937 random{0x726f7773};
  auto snapshot = [&](std::uint16_t cols, std::uint16_t rows, std::uint64_t pane) {
    Fixture f{cols, rows, pane, a.frameId() + 1, 0};
    f.range(0, cols * rows, random());
    compare(f);
  };
  for (std::uint16_t cols = 1; cols <= 7; ++cols) {
    for (std::uint16_t rows = 1; rows <= 3; ++rows) {
      snapshot(cols, rows, 1);
      const unsigned count = cols * rows;
      for (unsigned first = 0; first < count; ++first) {
        for (unsigned length = 1; length <= count - first; ++length) {
          Fixture f{cols, rows, 1, a.frameId() + 1, a.frameId()};
          f.range(first, length, random());
          compare(f);
        }
      }
    }
  }
  for (unsigned iteration = 0; iteration < 2048; ++iteration) {
    if (iteration % 17 == 0) {
      snapshot(1 + random() % 82, 1 + random() % 21, 1 + iteration / 31);
    }
    if (iteration % 71 == 0) {
      a.detach();
      b.detach();
      snapshot(a.columns(), a.rows(), a.paneId());
    }
    const unsigned count = a.columns() * a.rows();
    Fixture f{a.columns(), a.rows(), a.paneId(), a.frameId() + 1, a.frameId()};
    if (iteration % 11 != 0) {
      unsigned position = random() % count;
      while (position < count && f.spans.size() < 8) {
        const unsigned length = 1 + random() % (count - position);
        f.range(position, length, random());
        position += length + random() % 3;
      }
    }
    if (iteration % 13 == 0 && !f.encoded.empty()) {
      f.encoded.back().pop_back();
    }
    if (iteration % 19 == 0 && !f.encoded.empty()) {
      f.encoded.back().push_back(0);
    }
    if (iteration % 23 == 0) {
      f.frame.base_frame_id = f.frame.frame_id;
    }
    if (iteration % 29 == 0 && !f.spans.empty()) {
      f.spans.back().count = 0;
    }
    compare(f);
    if (iteration % 37 == 0) {
      f.frame.frame_id = a.frameId();
      f.frame.base_frame_id = a.frameId() - 1;
      compare(f);
    }
  }
  snapshot(65535, 1, 2);
  snapshot(1, 65535, 3);
  snapshot(3, 43453, 4);
  std::cout << "{\"reader_checks\":" << reader_checks << ",\"checks\":" << checks << ",\"errors\":" << errors << ",\"allocation_cases\":" << allocation_cases << ",\"allocation_failures\":" << allocation_failures << ",\"allocation_free_recoveries\":" << allocation_free_recoveries << ",\"digest\":" << digest << ",\"live_bytes\":" << memoryA.liveBytes() << ",\"allocations\":" << memoryA.allocations() << "}\n";
  return 0;
}

int main() {
  try {
    return exercise();
  } catch (const std::exception &error) {
    std::cerr << error.what() << "\n";
    return 1;
  }
}
