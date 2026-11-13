#include <termios.h>
#include <cerrno>
#include <cstdio>
#include <unistd.h>

import std;
import telar.runtime.tests.protocol_peer;

using namespace telar;

static void require(bool condition, std::string_view message) {
  if (!condition) {
    throw std::runtime_error{std::string{message}};
  }
}

static void writeOutput(std::string_view bytes) {
  while (!bytes.empty()) {
    const auto count = ::write(STDOUT_FILENO, bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }
    require(count > 0, "Cannot write graphics limit fixture");
    bytes.remove_prefix(static_cast<std::size_t>(count));
  }
}

static std::string transmit(unsigned image) {
  return "\x1b_Ga=t,f=32,s=1,v=1,i=" + std::to_string(image) + ",q=2;/wAA/w==\x1b\\";
}

static std::string place(unsigned image, unsigned placement, bool placeholders = false) {
  return "\x1b_Ga=p,i=" + std::to_string(image) + ",p=" + std::to_string(placement) + ",C=1,c=1,r=1,q=2" + (placeholders ? ",U=1;" : ";") + "\x1b\\";
}

static std::string readResponse() {
  std::string response;
  char byte = 0;
  while (response.size() < 256 && ::read(STDIN_FILENO, &byte, 1) == 1) {
    response += byte;
    if (response.ends_with("\x1b\\")) {
      return response;
    }
  }
  throw SocketError{"Graphics fixture did not receive its response"};
}

static void drawCase(char command) {
  if (command == 'E') {
    writeOutput("\x1b[?1049l");
    return;
  }

  writeOutput("\x1b[?1049l\x1b_Ga=d,d=A,q=2;\x1b\\\x1b[2J\x1b[H");
  if (command == 'A' || command == 'D') {
    std::string output;
    for (unsigned image = 1; image <= 80; ++image) {
      output += transmit(image);
    }
    if (command == 'D') {
      output += "\x1b[?1049h";
      for (unsigned image = 101; image <= 180; ++image) {
        output += transmit(image);
      }
    }
    writeOutput(output);
    return;
  }

  writeOutput(transmit(1) + transmit(2));
  if (command == 'B') {
    writeOutput(place(2, 129) + "\x1b[8;1H\n\n\n\n\n\n\n\n");
  } else {
    writeOutput("\x1b_Ga=p,i=2,p=129,C=1,c=1,r=4,q=2;\x1b\\\x1b[8;1H\n\n");
  }
  std::string placements;
  for (unsigned placement = 1; placement <= 128; ++placement) {
    placements += place(1, placement, command == 'B');
  }
  writeOutput(placements);
}

static int child() {
  termios settings{};
  require(::tcgetattr(STDIN_FILENO, &settings) == 0, "Cannot read fixture terminal settings");
  ::cfmakeraw(&settings);
  require(::tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0, "Cannot set fixture terminal settings");
  writeOutput("\x1b[Hr");
  unsigned sequence = 0;
  char command = 0;
  while (::read(STDIN_FILENO, &command, 1) == 1 && command != 'q') {
    if (command == 'U') {
      writeOutput("\x1b_Ga=t,f=32,s=1,v=1,i=77,m=1,q=2;/wAA\x1b\\");
      std::string continuations;
      constexpr unsigned maximum_chunks = 128 * 1024 * 1024 / 3072;
      for (unsigned index = 0; index < maximum_chunks; ++index) {
        continuations += "\x1b_Gm=1;\x1b\\";
      }
      writeOutput(continuations);
      require(readResponse() == "\x1b_Gi=77;ENOMEM: graphics upload limit exceeded\x1b\\", "Wrong incomplete upload response");
    } else {
      drawCase(command);
      writeOutput("\x1b_Ga=q,f=32,s=1,v=1,i=999;/wAA/w==\x1b\\");
      require(readResponse() == "\x1b_Gi=999;OK\x1b\\", "Graphics query barrier failed");
    }
    writeOutput(std::string{"\x1b[H"} + static_cast<char>('a' + sequence++ % 26));
  }
  return 0;
}

static void waitMarker(ProtocolPeer &peer, char marker) {
  for (;;) {
    const auto message = peer.receiveAny<PaneFrame, PaneExited>();
    require(std::holds_alternative<PaneFrame>(message), "Graphics child exited before its completion marker");
    const auto &frame = std::get<PaneFrame>(message);
    peer.send(FrameAck{frame.pane_id, frame.frame_id});
    for (const auto &span : frame.spans) {
      auto reader = span.reader();
      for (std::size_t index = 0; index < span.count; ++index) {
        const auto cell = reader.next();
        if (span.start + index == 0 && cell && cell->text.size() == 1 && cell->text[0] == static_cast<Byte>(marker)) {
          return;
        }
      }
    }
  }
}

static void snapshot(ProtocolPeer &peer, std::uint64_t pane, char scenario, std::ostream &dump) {
  peer.send(RequestGraphicsSnapshot{pane});
  while (peer.receive<GraphicsSnapshot>().phase != SnapshotPhase::begin) {
  }

  std::map<std::uint32_t, ImageDescription> images;
  std::map<std::uint64_t, GraphicsPlacement> placements;
  std::map<std::uint32_t, std::vector<Byte>> pixels;
  for (;;) {
    auto message = peer.receiveAny<GraphicsSnapshot, GraphicsImage, GraphicsImageChunk, GraphicsPlacementMessage>();
    if (const auto *phase = std::get_if<GraphicsSnapshot>(&message)) {
      require(phase->phase == SnapshotPhase::end, "Unexpected nested graphics snapshot");
      break;
    }
    if (const auto *image = std::get_if<GraphicsImage>(&message)) {
      images[image->image.key.image_id] = image->image;
    } else if (const auto *chunk = std::get_if<GraphicsImageChunk>(&message)) {
      auto &bytes = pixels[chunk->key.image_id];
      require(chunk->offset == bytes.size(), "Invalid snapshot chunk offset");
      bytes.insert(bytes.end(), chunk->bytes.begin(), chunk->bytes.end());
      if (bytes.size() == images.at(chunk->key.image_id).byte_len) {
        peer.send(GraphicsCredit{pane, bytes.size()});
      }
    } else if (const auto *placement = std::get_if<GraphicsPlacementMessage>(&message)) {
      placements[placement->placement.virtual_id] = placement->placement;
    }
  }

  const std::size_t expected_images = scenario == 'U' ? 0 : scenario == 'B' || scenario == 'C' ? 2
                                                                                               : 32;
  require(images.size() == expected_images, "Wrong retained image count");
  require(placements.size() == ((scenario == 'B' || scenario == 'C') ? 128 : 0), "Wrong retained placement count");
  for (auto &[identity, image] : images) {
    require(pixels.at(identity) == std::vector<Byte>{255, 0, 0, 255}, "Wrong retained image bytes");
    if (scenario == 'A' || scenario == 'E') {
      require(identity >= 49 && identity <= 80, "Old images survived eviction");
    } else if (scenario == 'D') {
      require(identity >= 149 && identity <= 180, "Old alternate images survived eviction");
    }
    image.key.generation = 1;
    peer.record(dump, GraphicsImage{.header = {1, 1}, .image = image});
  }
  for (auto &[identity, placement] : placements) {
    placement.key.generation = 1;
    peer.record(dump, GraphicsPlacementMessage{.header = {1, 1}, .placement = placement});
  }
}

int main(int argc, char **argv) {
  try {
    if (argc == 2 && std::string_view{argv[1]} == "--child") {
      return child();
    }
    if (argc != 5) {
      return 2;
    }
    ProtocolPeer peer{argv[1]};
    const std::array<std::string_view, 2> arguments{argv[0], "--child"};
    const auto pane = peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {20, 8, 8, 16}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}}).pane_id;
    waitMarker(peer, 'r');
    std::ofstream dump{argv[4], std::ios::binary};
    const unsigned iterations = static_cast<unsigned>(std::stoul(argv[3]));
    const auto started = std::chrono::steady_clock::now();
    const std::string_view scenarios = std::string_view{argv[2]} == "graphics-uploads" ? "U" : "ABCDE";
    unsigned sequence = 0;
    for (unsigned iteration = 0; iteration < iterations; ++iteration) {
      for (const char scenario : scenarios) {
        const std::array<Byte, 1> command{static_cast<Byte>(scenario)};
        peer.send(PaneInput{pane, command});
        waitMarker(peer, static_cast<char>('a' + sequence++ % 26));
        snapshot(peer, pane, scenario, dump);
      }
    }
    auto limits = peer.exchange<LimitList>(QueryLimits{1});
    for (const auto &entry : limits.entries) {
      dump << entry.reach.name << ':' << entry.reach.value << '\n';
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    const std::array<Byte, 1> quit{'q'};
    peer.send(PaneInput{pane, quit});
    std::printf("{\"iterations\":%u,\"elapsed_ns\":%lld,\"ns_per_iteration\":%lld}\n", iterations, static_cast<long long>(elapsed), static_cast<long long>(elapsed / iterations));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "graphics-limits-probe: %s\n", error.what());
    return 1;
  }
}
