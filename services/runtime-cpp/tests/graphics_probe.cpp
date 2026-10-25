#include "protocol_peer.hpp"
#include "text/base64.hpp"
#include <chrono>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <termios.h>

using namespace telar;

static void writeAll(std::string_view bytes) {
  while (!bytes.empty()) {
    const auto count = ::write(STDOUT_FILENO, bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      throw SocketError{"Graphics fixture write failed"};
    }
    bytes.remove_prefix(static_cast<std::size_t>(count));
  }
}

static std::string encodeBase64(std::span<const Byte> bytes) {
  std::string result((bytes.size() + 2) / 3 * 4, '\0');
  if (runtime::base64::encode(bytes, result) != result.size()) {
    throw SocketError{"Cannot encode graphics fixture"};
  }
  return result;
}

class ChildImageResource {
public:
  explicit ChildImageResource(bool shared)
      : shared_(shared) {}

  ~ChildImageResource() {
    clear();
  }

  void transmit(std::span<const Byte> pixels, bool atomic) {
    if (shared_ && !name_.empty()) {
      const int retained = ::shm_open(name_.c_str(), O_RDONLY, 0);
      if (retained >= 0) {
        ::close(retained);
        throw SocketError{"Runtime did not unlink the child shared object"};
      }
    }
    clear();

    std::array<char, 64> name;
    int descriptor;
    if (shared_) {
      std::snprintf(name.data(), name.size(), "/tlrprobe%08x%08x", ::arc4random(), ::arc4random());
      descriptor = ::shm_open(name.data(), O_CREAT | O_EXCL | O_RDWR, 0600);
    } else {
      std::strcpy(name.data(), "/tmp/telar-graphics-probe-XXXXXX");
      descriptor = ::mkstemp(name.data());
    }
    if (descriptor < 0) {
      throw SocketError{"Cannot create graphics fixture resource"};
    }
    name_ = name.data();
    const std::size_t offset = atomic ? 0 : 64;
    const auto length = offset + pixels.size();
    if (::ftruncate(descriptor, static_cast<off_t>(length)) != 0) {
      ::close(descriptor);
      throw SocketError{"Cannot size graphics fixture resource"};
    }

    void *mapping = ::mmap(nullptr, length, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    ::close(descriptor);
    if (mapping == MAP_FAILED) {
      throw SocketError{"Cannot map graphics fixture resource"};
    }
    std::memcpy(static_cast<Byte *>(mapping) + offset, pixels.data(), pixels.size());
    ::munmap(mapping, length);
    const auto encoded = encodeBase64({reinterpret_cast<const Byte *>(name_.data()), name_.size()});
    const std::string medium = shared_ ? "s" : "f";
    if (atomic) {
      writeAll("\x1b[?2026h\x1b[H\x1b_Ga=T,t=" + medium + ",f=32,s=256,v=256,i=1,p=3,C=1,q=2;" + encoded + "\x1b\\\x1b[?2026l");
    } else {
      writeAll("\x1b_Ga=T,t=" + medium + ",f=32,s=256,v=256,i=1,p=3,c=20,r=10,C=1,q=2,O=64,S=" + std::to_string(pixels.size()) + ";" + encoded + "\x1b\\");
    }
  }

private:
  void clear() noexcept {
    if (!name_.empty()) {
      if (shared_) {
        ::shm_unlink(name_.c_str());
      } else {
        ::unlink(name_.c_str());
      }
      name_.clear();
    }
  }

  bool shared_;
  std::string name_;
};

static int graphicsChild(std::string_view workload) {
  termios settings{};
  if (::tcgetattr(STDIN_FILENO, &settings) != 0) {
    return 2;
  }
  ::cfmakeraw(&settings);
  if (::tcsetattr(STDIN_FILENO, TCSANOW, &settings) != 0) {
    return 2;
  }
  writeAll("ready");
  std::vector<Byte> pixels(256 * 256 * 4);
  const bool external = workload.starts_with("graphics-file") || workload.starts_with("graphics-shm");
  const bool atomic = workload.find("-atomic") != std::string_view::npos;
  ChildImageResource resource{workload.starts_with("graphics-shm")};
  unsigned sequence = 0;
  char command = 0;
  while (::read(STDIN_FILENO, &command, 1) == 1) {
    if (command == 'q') {
      return 0;
    }
    if (command == 'd') {
      writeAll("\x1b_Ga=d,d=I,i=1,q=2;\x1b\\");
      continue;
    }
    for (std::size_t index = 0; index < pixels.size(); index += 4) {
      pixels[index] = static_cast<Byte>(sequence);
      pixels[index + 1] = static_cast<Byte>(index / 4);
      pixels[index + 2] = 17;
      pixels[index + 3] = 255;
    }
    writeAll("\x1b[2;3H");
    if (external) {
      resource.transmit(pixels, atomic);
      ++sequence;
      continue;
    }

    const auto encoded = encodeBase64(pixels);
    std::size_t offset = 0;
    while (offset < encoded.size()) {
      const auto take = std::min<std::size_t>(4096, encoded.size() - offset);
      const bool more = offset + take != encoded.size();
      std::string header = offset == 0 ? "\x1b_Ga=T,f=32,s=256,v=256,i=1,p=3,c=20,r=10,C=1,q=2,m=" : "\x1b_Gm=";
      header += more ? "1;" : "0;";
      writeAll(header);
      writeAll(std::string_view{encoded}.substr(offset, take));
      writeAll("\x1b\\");
      offset += take;
    }
    ++sequence;
  }
  return 0;
}

static ImageDescription image(ProtocolPeer &peer, bool shared, std::vector<Byte> &pixels) {
  if (shared) {
    const auto message = peer.receive<GraphicsSharedImage>();
    const std::string name{message.name};
    const auto description = message.image;
    const int descriptor = ::shm_open(name.c_str(), O_RDONLY, 0);
    if (descriptor < 0) {
      throw SocketError{"Shared image missing"};
    }
    struct stat status{};
    if (::fstat(descriptor, &status) != 0 || status.st_size < static_cast<off_t>(description.byte_len)) {
      throw SocketError{"Shared image size mismatch"};
    }
    const void *mapping = ::mmap(nullptr, description.byte_len, PROT_READ, MAP_SHARED, descriptor, 0);
    ::close(descriptor);
    if (mapping == MAP_FAILED) {
      throw SocketError{"Shared image mapping failed"};
    }
    pixels.assign(static_cast<const Byte *>(mapping), static_cast<const Byte *>(mapping) + description.byte_len);
    ::munmap(const_cast<void *>(mapping), description.byte_len);
    ::shm_unlink(name.c_str());
    return description;
  }
  const auto description = peer.receive<GraphicsImage>().image;
  pixels.clear();
  while (pixels.size() != description.byte_len) {
    const auto chunk = peer.receive<GraphicsImageChunk>();
    if (chunk.key.image_id != description.key.image_id || chunk.key.generation != description.key.generation || chunk.offset != pixels.size() || chunk.bytes.size() > description.byte_len - pixels.size()) {
      throw SocketError{"Invalid image transfer"};
    }
    pixels.insert(pixels.end(), chunk.bytes.begin(), chunk.bytes.end());
  }
  return description;
}

int main(int argc, char **argv) {
  try {
    if (argc == 3 && std::string_view{argv[1]} == "--child") {
      return graphicsChild(argv[2]);
    }
    if (argc != 5 && (argc != 6 || std::string_view{argv[5]} != "retain")) {
      return 2;
    }
    ProtocolPeer peer{argv[1]};
    const bool shared = std::string_view{argv[2]}.ends_with("-shared");
    const auto iterations = static_cast<unsigned>(std::stoul(argv[3]));
    const std::array<std::string_view, 3> arguments{argv[0], "--child", argv[2]};
    const auto pane = peer.exchange<PaneOpened>(OpenPane{.request_id = 1,
                                                         .size = {80, 24, 8, 16},
                                                         .launch = Launch{.cwd = "/tmp",
                                                                          .arguments = arguments}});
    for (;;) {
      const auto frame = peer.receive<PaneFrame>();
      peer.send(FrameAck{frame.pane_id, frame.frame_id});
      bool ready = false;
      for (const auto &span : frame.spans) {
        auto reader = span.reader();
        for (std::size_t index = 0; index < span.count; ++index) {
          const auto cell = reader.next();
          ready |= span.start + index == 0 && cell && cell->text.size() == 1 && cell->text[0] == 'r';
        }
      }
      if (ready) {
        break;
      }
    }
    peer.send(ConfigureGraphics{shared});
    std::ofstream dump{argv[4], std::ios::binary};
    std::vector<Byte> pixels;
    std::uint64_t previous_generation = 0;
    const auto started = std::chrono::steady_clock::now();
    for (unsigned index = 0; index < iterations; ++index) {
      const std::array<Byte, 1> next{'n'};
      peer.send(PaneInput{pane.pane_id, next});
      auto description = image(peer, shared, pixels);
      auto placed = peer.receive<GraphicsPlacementMessage>();
      if (description.key.generation == previous_generation || placed.placement.key.generation != description.key.generation || pixels.size() != 256 * 256 * 4 || pixels[0] != static_cast<Byte>(index) || pixels[3] != 255) {
        throw SocketError{"Graphics state mismatch"};
      }
      previous_generation = description.key.generation;
      peer.send(GraphicsCredit{pane.pane_id, description.byte_len});
      description.key.generation = index + 1;
      placed.header = {1, index + 1};
      placed.placement.key.generation = index + 1;
      peer.record(dump, GraphicsImage{.header = placed.header,
                                      .image = description});
      dump.write(reinterpret_cast<const char *>(pixels.data()), static_cast<std::streamsize>(pixels.size()));
      peer.record(dump, placed);
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    if (argc == 6) {
      std::puts("retained");
      std::fflush(stdout);
      if (std::getchar() != '\n') {
        throw SocketError{"Retained graphics fixture lost its release signal"};
      }
    }

    const std::array<Byte, 1> remove{'d'};
    peer.send(PaneInput{pane.pane_id, remove});
    while (peer.receive<GraphicsDeleteImage>().key.generation != previous_generation) {
    }
    peer.send(RequestGraphicsSnapshot{pane.pane_id});
    if (peer.receive<GraphicsSnapshot>().phase != SnapshotPhase::begin || peer.receive<GraphicsSnapshot>().phase != SnapshotPhase::end) {
      throw SocketError{"Empty graphics snapshot mismatch"};
    }
    const std::array<Byte, 1> quit{'q'};
    peer.send(PaneInput{pane.pane_id, quit});
    std::printf("{\"iterations\":%u,\"elapsed_ns\":%lld,\"ns_per_iteration\":%lld}\n", iterations, static_cast<long long>(elapsed), static_cast<long long>(elapsed / iterations));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "graphics-probe: %s\n", error.what());
    return 1;
  }
}
