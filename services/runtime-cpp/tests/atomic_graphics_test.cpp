#include "check.hpp"
#include "graphics/atomic_frame_filter.hpp"
#include "graphics/frame_source.hpp"
#include <cstring>
#include <filesystem>
#include <set>
#include <string>
#include <vector>

using namespace telar;
using namespace telar::runtime;

static std::span<const std::uint8_t> atomicBytes(std::string_view text) {
  return {reinterpret_cast<const std::uint8_t *>(text.data()), text.size()};
}

static std::string atomicFrame(std::string_view name, unsigned image = 1, unsigned placement = 2, bool wrapped = false) {
  const auto frame = std::string{AtomicFrame::prefix} + "a=T,t=s,f=32,s=2,v=3,i=" + std::to_string(image) + ",p=" + std::to_string(placement) + ",C=1,q=2;" + std::string{name} + std::string{AtomicFrame::suffix};
  return wrapped ? std::string{AtomicFrame::cursor_save} + frame + std::string{AtomicFrame::cursor_restore} : frame;
}

struct AtomicSourceFixture {
  std::set<std::string> names{};
  std::vector<std::string> probes{};
  std::vector<std::string> released{};

  bool available(const AtomicFrameResource &resource) {
    probes.emplace_back(resource.encoded_name);
    return resource.byte_count <= resource.limit && names.contains(std::string{resource.encoded_name});
  }

  void release(const AtomicFrameResource &resource) {
    released.emplace_back(resource.encoded_name);
  }
};

struct AtomicSinkFixture {
  std::string output_bytes{};
  std::vector<std::string> frames{};
  bool accept = false;

  void output(std::span<const std::uint8_t> bytes) {
    output_bytes.append(reinterpret_cast<const char *>(bytes.data()), bytes.size());
  }

  bool atomicFrame(const AtomicFrameView &frame) {
    check(frame.command_start < frame.command_end && frame.command_end <= frame.bytes.size());
    frames.emplace_back(frame.encoded_name);
    return accept;
  }
};

static void testAtomicParsing() {
  const std::string control = "a=T,t=s,f=32,s=2,v=3,i=1,p=2,C=1,q=2";
  const auto parsed = AtomicFrameControl::parse(control);
  check(parsed && parsed->byte_count == 24 && parsed->key == AtomicFrameKey{1, 2});
  check(AtomicFrameControl::parse("q=2,C=1,p=2,i=1,v=3,s=2,f=24,t=f,a=T")->byte_count == 18);
  for (const auto extra : {",m=0", ",S=24", ",O=0", ",z=1", ",c=1", ",x=0", ",a=T", ",t=s", ",f=32", ",s=2", ",v=3", ",i=1", ",p=2", ",C=1", ",q=2", ","}) {
    check(!AtomicFrameControl::parse(control + extra));
  }
  for (const auto rejected : {"a=t,t=s,f=32,s=2,v=3,i=1,p=2,C=1,q=2", "a=T,t=s,f=100,s=2,v=3,i=1,p=2,C=1,q=2", "a=T,t=s,f=32,s=2,v=3,i=1,p=0,C=1,q=2", "a=T,t=s,f=32,s=2,v=3,i=1,p=2,C=0,q=2", "a=T,t=s,f=32,s=2,v=3,i=1,p=2,C=1,q=1", "a=T,t=s,f=32,s=4294967295,v=4294967295,i=1,p=2,C=1,q=2"}) {
    check(!AtomicFrameControl::parse(rejected));
  }

  for (const bool wrapped : {false, true}) {
    const auto frame = atomicFrame("first", 1, 2, wrapped);
    const auto parsed_frame = AtomicFrame::at(frame, 0);
    check(parsed_frame && parsed_frame->end == frame.size() && parsed_frame->cursor_wrapped == wrapped);
    check(parsed_frame->encoded_name == "first" && parsed_frame->control.byte_count == 24);
    check(frame.substr(parsed_frame->command_start, 3) == "\x1b_G");
    for (std::size_t cut = 0; cut < frame.size(); ++cut) {
      check(!AtomicFrame::at(std::string_view{frame}.substr(0, cut), 0));
    }
    const auto found = AtomicFrame::find("prefix" + frame + "suffix", 0);
    check(found && found->start == 6 && found->end == 6 + frame.size());
  }
}

static void testAtomicSelection() {
  const auto first = atomicFrame("first");
  const auto second = atomicFrame("second", 9, 2);
  const auto newest = atomicFrame("newest");
  AtomicSourceFixture source{.names = {"first", "second", "newest"}};
  AtomicSinkFixture sink;
  auto statistics = AtomicFrameFilter::feed(atomicBytes("before" + first + second + newest + "after"), 24, source, sink);
  check(sink.output_bytes == "before" + second + newest + "after");
  check(source.released == std::vector<std::string>{"first"});
  check(sink.frames == std::vector<std::string>{"second", "newest"});
  check(statistics.discarded == 1 && statistics.forwarded == 2 && statistics.unavailable == 0);

  source = {.names = {"first", "second"}};
  sink = {};
  statistics = AtomicFrameFilter::feed(atomicBytes(first + newest), 24, source, sink);
  check(sink.output_bytes == first && source.probes == std::vector<std::string>{"newest", "first"});
  check(source.released == std::vector<std::string>{"newest"} && statistics.discarded == 1);

  source = {};
  sink = {};
  statistics = AtomicFrameFilter::feed(atomicBytes(first + newest), 24, source, sink);
  check(sink.output_bytes.empty() && source.released.size() == 2 && statistics.unavailable == 2);

  source = {.names = {"first", "newest"}};
  sink = {};
  statistics = AtomicFrameFilter::feed(atomicBytes(first + "separator" + newest), 24, source, sink);
  check(sink.output_bytes == first + "separator" + newest && statistics.forwarded == 2 && source.released.empty());

  source = {.names = {"first", "newest"}};
  sink = {};
  statistics = AtomicFrameFilter::feed(atomicBytes(atomicFrame("first", 1, 2, true) + newest), 24, source, sink);
  check(sink.output_bytes == std::string{AtomicFrame::cursor_save} + newest && statistics.discarded == 1);
}

static void testAtomicBoundsAndTransport() {
  std::string group;
  for (unsigned index = 0; index < 9; ++index) {
    group += atomicFrame(std::to_string(index));
  }
  AtomicSourceFixture source{.names = {"0"}};
  AtomicSinkFixture sink;
  auto statistics = AtomicFrameFilter::feed(atomicBytes(group), 24, source, sink);
  check(sink.output_bytes.empty() && source.probes.size() == 8 && statistics.unavailable == 9);

  group.clear();
  for (unsigned image = 1; image <= 257; ++image) {
    group += atomicFrame("same", image);
  }
  source = {.names = {"same"}};
  sink = {};
  statistics = AtomicFrameFilter::feed(atomicBytes(group), 24, source, sink);
  check(sink.output_bytes == group && source.probes.empty() && source.released.empty() && statistics.forwarded == 0);

  const auto frame = atomicFrame("same");
  source = {.names = {"same"}};
  sink = {};
  statistics = AtomicFrameFilter::feed(atomicBytes(frame), 23, source, sink);
  check(statistics.unavailable == 1 && sink.output_bytes.empty());

  source = {.names = {"same"}};
  sink = {.accept = true};
  statistics = AtomicFrameFilter::feed(atomicBytes(frame), 24, source, sink);
  check(statistics.direct == 1 && statistics.forwarded == 1 && statistics.file == 0 && sink.output_bytes.empty());

  auto file = frame;
  file.replace(file.find("t=s"), 3, "t=f");
  source = {.names = {"same"}};
  sink = {};
  statistics = AtomicFrameFilter::feed(atomicBytes(file), 24, source, sink);
  check(statistics.unavailable == 1 && statistics.forwarded == 0 && sink.output_bytes.empty());
  sink = {.accept = true};
  statistics = AtomicFrameFilter::feed(atomicBytes(file), 24, source, sink);
  check(statistics.file == 1 && statistics.direct == 1 && statistics.forwarded == 1);
}

static std::string encodedName(std::string_view name) {
  std::string encoded((name.size() + 2) / 3 * 4, '\0');
  check(base64::encode(atomicBytes(name), encoded) == encoded.size());
  return encoded;
}

static void testAtomicResources() {
  std::array<char, 64> path;
  std::strcpy(path.data(), "/tmp/telar-atomic-file-XXXXXX");
  FileDescriptor file{::mkstemp(path.data())};
  check(file && ::ftruncate(file.get(), 8) == 0);
  const auto encoded = encodedName(path.data());
  const AtomicFrameResource resource{encoded, 8, 8, GraphicsInputMedium::file};
  check(GraphicsFrameSource::available(resource));
  check(!GraphicsFrameSource::available({encoded, 9, 9, GraphicsInputMedium::file}));
  check(!GraphicsFrameSource::available({encoded, 8, 7, GraphicsInputMedium::file}));
  GraphicsFrameSource::release(resource);
  check(std::filesystem::exists(path.data()));

  const auto symlink = std::string{path.data()} + ".symlink";
  const auto pipe = std::string{path.data()} + ".pipe";
  std::filesystem::create_symlink(path.data(), symlink);
  check(::mkfifo(pipe.c_str(), 0600) == 0);
  for (const auto &name : {symlink, pipe, std::string{"relative-file"}}) {
    const auto encoded = encodedName(name);
    check(!GraphicsFrameSource::available({encoded, 1, 8, GraphicsInputMedium::file}));
  }
  std::filesystem::remove(symlink);
  std::filesystem::remove(pipe);
  std::filesystem::remove(path.data());

  std::array<char, 32> shared_name;
  std::snprintf(shared_name.data(), shared_name.size(), "/tlratom%08x%08x", ::arc4random(), ::arc4random());
  FileDescriptor shared{::shm_open(shared_name.data(), O_CREAT | O_EXCL | O_RDWR, 0600)};
  check(shared && ::ftruncate(shared.get(), 8) == 0);
  const auto encoded_shared = encodedName(shared_name.data());
  const AtomicFrameResource shared_resource{encoded_shared, 16, 16, GraphicsInputMedium::shared_memory};
  check(GraphicsFrameSource::available(shared_resource));
  GraphicsFrameSource::release(shared_resource);
  check(!GraphicsFrameSource::available(shared_resource));

  std::array<std::uint8_t, 4> decoded;
  check(decodeGraphicsName("YWJj", decoded) != nullptr && std::strcmp(reinterpret_cast<const char *>(decoded.data()), "abc") == 0);
  for (const auto invalid : {"", "AAAA", "YWJjZA==", "YWJj!"}) {
    check(decodeGraphicsName(invalid, decoded) == nullptr);
  }
}

void testAtomicGraphics() {
  testAtomicParsing();
  testAtomicSelection();
  testAtomicBoundsAndTransport();
  testAtomicResources();
}
