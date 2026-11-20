#include <cstdlib>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.base.text;
import telar.config.core;
import telar.runtime.terminal.graphics.pane_media;
import telar.runtime.terminal.control;
import telar.runtime.terminal.graphics_storage;
import telar.runtime.terminal.kitty;
import telar.wire.vocabulary;
import telar.testing;
import telar.testing.test_memory;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::span<const Byte> bytes(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()};
  }

  std::string encode(std::string_view text) {
    std::string encoded((text.size() + 2) / 3 * 4, '\0');

    check(base64::encode(bytes(text), encoded) == encoded.size());
    return encoded;
  }

  // A fresh directory under the system temp directory, removed when the case ends.
  struct Directory {
    std::filesystem::path path;

    Directory() {
      auto pattern = (std::filesystem::temp_directory_path() / "telar-media-file-XXXXXX").string();

      check(::mkdtemp(pattern.data()) != nullptr);
      path = pattern;
    }

    ~Directory() {
      std::filesystem::remove_all(path);
    }

    std::string write(std::string_view name, std::span<const Byte> contents) const {
      const auto file = path / name;
      std::ofstream stream{file, std::ios::binary};

      stream.write(reinterpret_cast<const char*>(contents.data()), static_cast<std::streamsize>(contents.size()));
      check(stream.good());
      return file.string();
    }
  };

  // A media terminal over its own budget, as a pane's media worker runs one.
  struct Media {
    telar::testing::TestMemory adapter;
    MediaBudget budget{GraphicsLimits::maximum_global_bytes};
    MediaAllocator<ConcurrentMemory> allocator{adapter, budget, GraphicsLimits::maximum_pane_bytes};
    MediaTerminal terminal;

    explicit Media(GraphicsLimits limits = {})
        : terminal{allocator, TerminalSize{80, 24, 8, 16}, limits} {}

    std::span<const GraphicsImageView> feed(std::string_view input) {
      terminal.feed(bytes(input));
      terminal.refresh();
      return terminal.graphics().images();
    }

    std::string responses() {
      const auto pending = terminal.responses();
      std::string result{reinterpret_cast<const char*>(pending.data()), pending.size()};

      if (!pending.empty()) {
        terminal.consumeResponses(pending.size());
      }

      return result;
    }
  };

  std::vector<Byte> pattern(std::size_t size) {
    std::vector<Byte> result(size);

    for (std::size_t index = 0; index < size; ++index) {
      result[index] = static_cast<Byte>(index * 131 + index / 251);
    }

    return result;
  }

  std::string fileUpload(std::string_view control, std::string_view path) {
    return "\x1b_G" + std::string{control} + ";" + encode(path) + "\x1b\\";
  }

  // The reply a refused upload gets: an error for its image, never OK.
  bool refused(std::string_view reply) {
    return reply.starts_with("\x1b_Gi=1;E") && reply.ends_with("\x1b\\") && !reply.contains(";OK");
  }

  // A file upload reads only the range the program names, inside the file and within the
  // pane's storage: any other range stores no image, answers the program with an error and
  // leaves the file in place.
  void rangeOutsideFileRefused() {
    Directory directory;
    const auto pixels = directory.write("pixels", pattern(16));
    const auto empty = directory.write("empty", {});

    for (const auto control : {
             "a=T,t=f,f=32,s=1,v=1,i=1,O=17",
             "a=T,t=f,f=32,s=1,v=1,i=1,O=8,S=12",
             "a=T,t=f,f=32,s=1,v=1,i=1,S=17",
             "a=T,t=f,f=32,s=1,v=1,i=1,O=18446744073709551615",
             "a=T,t=f,f=32,s=1,v=1,i=1,O=18446744073709551616",
         }) {
      Media media;

      check(media.feed(fileUpload(control, pixels)).empty(), control);
      check(refused(media.responses()), control);
      check(std::filesystem::exists(pixels));
    }

    // A range the program writes wrong reads nothing.
    for (const auto control : {"a=T,t=f,f=32,s=1,v=1,i=1,O=-4", "a=T,t=f,f=32,s=1,v=1,i=1,S=4x", "a=T,t=f,f=32,s=1,v=1,i=1,O="}) {
      Media media;

      check(media.feed(fileUpload(control, pixels)).empty(), control);
      check(std::filesystem::exists(pixels));
    }

    {
      Media media;

      check(media.feed(fileUpload("a=T,t=f,f=32,s=1,v=1,i=1", empty)).empty());
      check(refused(media.responses()));
      check(std::filesystem::exists(empty));

      const auto inside = media.feed(fileUpload("a=T,t=f,f=32,s=1,v=1,i=2,q=1,O=12,S=4", pixels));

      check(inside.size() == 1 && std::ranges::equal(inside.front().pixels, pattern(16) | std::views::drop(12)));
    }

    Media small{GraphicsLimits{.pane_bytes = 1024 * 1024}};
    const auto side = static_cast<std::size_t>(std::sqrt(small.terminal.storageLimit() / 4)) + 1;
    const auto large = directory.write("large", pattern(side * side * 4));
    const auto control = "a=T,t=f,f=32,s=" + std::to_string(side) + ",v=" + std::to_string(side) + ",i=1";

    check(side * side * 4 > small.terminal.storageLimit());
    check(small.feed(fileUpload(control, large)).empty());
    check(refused(small.responses()));
    check(std::filesystem::exists(large));
  }

  // A file far larger than one chunk of the upload reaches the image whole: its pixels are
  // the file's bytes from the offset on, in order.
  void multiChunkFileExactPixels() {
    Directory directory;
    constexpr std::size_t side = 256;
    const auto contents = pattern(1000 + side * side * 4);
    const auto path = directory.write("pixels", contents);
    const auto size = ",s=" + std::to_string(side) + ",v=" + std::to_string(side);

    for (const std::size_t offset : {0, 1000}) {
      Media media;
      const auto control = "a=T,t=f,f=32,i=3,q=2" + size + ",O=" + std::to_string(offset) + ",S=" + std::to_string(side * side * 4);
      const auto images = media.feed(fileUpload(control, path));

      check(images.size() == 1);
      check(std::ranges::equal(images.front().pixels, std::span{contents}.subspan(offset, side * side * 4)));
    }
  }

  // However long a file upload's control is, the upload either stores the file's exact
  // pixels or nothing, and never fails the pane.
  void controlAtCapacity() {
    Directory directory;
    constexpr std::size_t side = 64;
    const auto contents = pattern(side * side * 4);
    const auto path = directory.write("pixels", contents);
    const std::string base = "a=T,t=f,f=32,s=" + std::to_string(side) + ",v=" + std::to_string(side) + ",i=5,q=2";
    std::size_t stored = 0;

    for (std::size_t length = 400; length <= 600; ++length) {
      auto control = base;

      while (length - control.size() > 7) {
        control.append(",z=0");
      }

      control.append(",z=");
      control.append(length - control.size(), '0');
      check(control.size() == length);
      Media media;
      const auto images = media.feed(fileUpload(control, path));

      check(images.empty() || (images.size() == 1 && std::ranges::equal(images.front().pixels, contents)));
      stored += images.size();
    }

    check(stored != 0);
  }

  // The media terminal shares the pane's input with the interactive terminal, which answers
  // the program's queries: it answers none, so the program gets each reply once. Its own
  // graphics replies still reach the program.
  void neverAnswersQueries() {
    Media media;

    for (const auto query : {
             "\x1b[c",
             "\x1b[>c",
             "\x1b[=c",
             "\x1bZ",
             "\x1b[5n",
             "\x1b[6n",
             "\x1b[?6n",
             "\x1b[?996n",
             "\x1b[?2026$p",
             "\x1b[4$p",
             "\x1b[>q",
             "\x1b[14t",
             "\x1b[16t",
             "\x1b[18t",
             "\x1b[?u",
             "\x1b]10;?\x1b\\",
             "\x1b]11;?\x07",
             "\x1b]4;1;?\x1b\\",
             "\x1bP+q544e\x1b\\",
             "\x1bP$qm\x1b\\",
             "\x05",
         }) {
      media.feed(query);
      check(media.responses().empty(), query);
    }

    media.feed("\x1b_Ga=T,f=32,s=2,v=2,i=31;AAAA\x1b\\");
    const auto reply = media.responses();

    check(reply.starts_with("\x1b_Gi=31;") && reply.ends_with("\x1b\\") && !reply.contains(";OK"));
  }

  // A program may hand telar a temporary file to read and delete: one named as the protocol
  // names them, in a temp directory, becomes the image and is gone afterwards.
  void temporaryFileDeletedWhenAuthorized() {
    Directory directory;
    const auto contents = pattern(16);
    const auto path = directory.write("tty-graphics-protocol-pixels", contents);
    Media media;
    const auto images = media.feed(fileUpload("a=T,t=t,f=32,s=2,v=2,i=1,q=2", path));

    check(images.size() == 1 && std::ranges::equal(images.front().pixels, contents));
    check(!std::filesystem::exists(path));
  }

  const telar::testing::Case case_range_outside_file_refused{"media_file.range_outside_file_refused", rangeOutsideFileRefused};
  const telar::testing::Case case_multi_chunk_file_exact_pixels{"media_file.multi_chunk_file_exact_pixels", multiChunkFileExactPixels};
  const telar::testing::Case case_control_at_capacity{"media_file.control_at_capacity", controlAtCapacity};
  const telar::testing::Case case_never_answers_queries{"media_terminal.never_answers_queries", neverAnswersQueries};
  const telar::testing::Case case_temporary_file_deleted_when_authorized{"media_file.temporary_file_deleted_when_authorized", temporaryFileDeletedWhenAuthorized};

}
