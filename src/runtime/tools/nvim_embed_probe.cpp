// Starts a real `nvim --embed`, attaches to it as the runtime's editor does and measures the
// conversation: how long a key takes to come back as a flushed redraw, how much of that the
// runtime spends decoding, and whether the assumptions the editor's design makes about Neovim
// hold with the configuration it loads.
//
//   nvim-embed-probe [--nvim PATH] [--clean] [--surfaces] [--samples N] [--file FILE] [--cwd DIR]
//
// --clean starts Neovim without the user's configuration; --surfaces asks it for the command
// line, the completion menu, messages and the tab line as events instead of cells.

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.platform.process;
import telar.vocabulary;
import telar.runtime.nvim.editor;
import telar.runtime.nvim.screen;
import telar.wire.nvim;

namespace {

  using namespace telar;
  using namespace telar::runtime;
  using Clock = std::chrono::steady_clock;
  using Microseconds = std::chrono::duration<double, std::micro>;

  struct Options {
    std::string nvim = "nvim";
    std::string file;
    std::string cwd = ".";
    std::size_t samples = 300;
    bool clean = false;
    bool surfaces = false;
  };

  struct Samples {
    std::vector<double> values;

    void add(Clock::duration elapsed) {
      values.push_back(Microseconds{elapsed}.count());
    }

    [[nodiscard]] double quantile(double fraction) {
      if (values.empty()) {
        return 0;
      }

      std::ranges::sort(values);
      return values[std::min(values.size() - 1, static_cast<std::size_t>(fraction * static_cast<double>(values.size())))];
    }

    void print(std::string_view name) {
      std::println("{:<34} n={:<5} p50={:>9.1f}us p99={:>9.1f}us max={:>9.1f}us", name, values.size(), quantile(0.50), quantile(0.99), quantile(1.0));
    }
  };

  // The conversation over a Neovim's pipes, with what the probe measures of it.
  class Session {
  public:
    Session(ConcurrentMemory& memory, const Options& options)
        : editor_(memory, {.columns = 120, .rows = 40}, {.command_line = options.surfaces, .completion = options.surfaces, .messages = options.surfaces, .tabs = options.surfaces}) {
      std::vector<std::string_view> arguments{options.nvim, "--embed"};

      if (options.clean) {
        arguments.emplace_back("--clean");
      }

      Command command{memory, Launch{.cwd = options.cwd, .arguments = arguments}, CommandPurpose::configured_helper};

      process_.emplace(command.specification({}));
      for (const auto descriptor : {process_->input(), process_->output(), process_->error()}) {
        ::fcntl(descriptor, F_SETFL, ::fcntl(descriptor, F_GETFL) | O_NONBLOCK);
      }
    }

    // Runs the pipes until `done` holds or the time is up; false when the time ran out.
    template <typename Done>
    bool pump(std::chrono::milliseconds limit, Done done) {
      const auto deadline = Clock::now() + limit;

      while (!done()) {
        if (Clock::now() >= deadline || editor_.state() == NvimState::failed || closed_) {
          return false;
        }

        ds::Array<pollfd, 3> descriptors{
            pollfd{.fd = process_->output(), .events = POLLIN, .revents = 0},
            pollfd{.fd = process_->error(), .events = POLLIN, .revents = 0},
            pollfd{.fd = process_->input(), .events = static_cast<short>(editor_.pending().empty() ? 0 : POLLOUT), .revents = 0},
        };

        if (::poll(descriptors.dataMut(), descriptors.size(), 20) < 0 && errno != EINTR) {
          return false;
        }

        if ((descriptors[2].revents & POLLOUT) != 0) {
          const auto bytes = editor_.pending();
          const auto count = ::write(process_->input(), bytes.data(), bytes.size());

          if (count > 0) {
            editor_.written(static_cast<std::size_t>(count));
          }
        }

        if ((descriptors[1].revents & POLLIN) != 0) {
          const auto count = ::read(process_->error(), buffer_.dataMut(), buffer_.size());

          if (count > 0) {
            error_bytes_ += static_cast<std::size_t>(count);
            // What the probe itself made Neovim say is shown; the rest is only counted.
            const std::string_view said{reinterpret_cast<const char*>(buffer_.data()), static_cast<std::size_t>(count)};
            if (said.contains("probe-")) {
              std::print("stderr: {}", said);
            }
          }
        }

        if ((descriptors[0].revents & (POLLIN | POLLHUP)) != 0) {
          const auto count = ::read(process_->output(), buffer_.dataMut(), buffer_.size());

          if (count == 0) {
            closed_ = true;
            continue;
          }

          if (count > 0) {
            const auto started = Clock::now();

            editor_.receive(buffer_.view().first(static_cast<std::size_t>(count)));
            decode_ += Clock::now() - started;
            received_ += static_cast<std::size_t>(count);
          }
        }

        const auto pulse = editor_.takePulse();

        if (pulse.flushed) {
          ++flushes_;
          last_flush_ = Clock::now();
        }
      }

      return true;
    }

    // Waits until Neovim has flushed and then written nothing for `quiet`.
    bool settle(std::chrono::milliseconds limit = std::chrono::seconds{10}, std::chrono::milliseconds quiet = std::chrono::milliseconds{250}) {
      return pump(limit, [&] {
        return flushes_ > 0 && editor_.pending().empty() && Clock::now() - last_flush_ > quiet;
      });
    }

    // Sends keys and measures until the next flush; none when no flush came.
    std::optional<Clock::duration> key(std::string_view keys, Clock::duration* decode = nullptr) {
      const auto flushes = flushes_;
      const auto decoded = decode_;
      const auto started = Clock::now();

      if (!editor_.input(keys)) {
        return std::nullopt;
      }

      if (!pump(std::chrono::seconds{2}, [&] {
            return flushes_ != flushes;
          })) {
        return std::nullopt;
      }

      if (decode != nullptr) {
        *decode = decode_ - decoded;
      }

      return last_flush_ - started;
    }

    NvimEditor& editor() {
      return editor_;
    }

    [[nodiscard]] std::size_t flushes() const {
      return flushes_;
    }

    [[nodiscard]] std::size_t received() const {
      return received_;
    }

    [[nodiscard]] std::size_t errorBytes() const {
      return error_bytes_;
    }

    [[nodiscard]] bool closed() const {
      return closed_;
    }

    void stop() {
      process_->closeInput();
      process_->signal(SIGTERM);
    }

  private:
    NvimEditor editor_;
    std::optional<PipeProcess> process_;
    ds::Array<std::uint8_t, 64 * 1024> buffer_{};
    Clock::duration decode_{};
    Clock::time_point last_flush_ = Clock::now();
    std::size_t flushes_ = 0;
    std::size_t received_ = 0;
    std::size_t error_bytes_ = 0;
    bool closed_ = false;
  };

  std::size_t placed(const NvimScreen& screen, NvimPlacement placement) {
    return static_cast<std::size_t>(std::ranges::count_if(screen.grids(), [&](const auto& grid) {
      return grid->placement == placement;
    }));
  }

  int run(const Options& options) {
    testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const auto started = Clock::now();
    Session session{memory, options};

    if (!session.pump(std::chrono::seconds{20}, [&] {
          return session.flushes() > 0;
        })) {
      std::println("FAILED before the first flush: {}", session.editor().failure());
      return 1;
    }

    const auto first_flush = Clock::now() - started;

    session.settle(std::chrono::seconds{30}, std::chrono::milliseconds{500});

    const auto& screen = session.editor().screen();

    std::println("neovim channel={} configuration={} surfaces={}", session.editor().channel(), options.clean ? "clean" : "user", options.surfaces);
    std::println("startup first_flush={:.1f}ms settled={:.1f}ms bytes={} stderr_bytes={}", Microseconds{first_flush}.count() / 1000, Microseconds{Clock::now() - started}.count() / 1000, session.received(), session.errorBytes());
    std::println("screen grids={} windows={} floats={} directory={:?}", screen.grids().size(), placed(screen, NvimPlacement::window), placed(screen, NvimPlacement::floating), screen.directory());

    if (!options.file.empty()) {
      session.editor().command(std::format("edit {}", options.file));
      session.settle();
    }

    // Typing: one letter at a time in insert mode, each timed to the flush that shows it.
    Samples typing;
    Samples typing_decode;

    session.key("<Esc>");
    session.key("ggO");
    session.settle(std::chrono::seconds{3}, std::chrono::milliseconds{150});

    for (std::size_t index = 0; index < options.samples; ++index) {
      Clock::duration decode{};
      const auto elapsed = session.key(index % 60 == 59 ? "<CR>" : "a", &decode);

      if (!elapsed) {
        break;
      }

      typing.add(*elapsed);
      typing_decode.add(decode);
    }

    typing.print("key to flush, typing");
    typing_decode.print("  of which the runtime decodes");
    session.key("<Esc>");
    session.key("u");
    session.settle(std::chrono::seconds{3}, std::chrono::milliseconds{150});

    // Scrolling a window one line and half a page at a time.
    Samples line_scroll;
    Samples line_decode;
    Samples page_scroll;
    Samples page_decode;

    for (std::size_t index = 0; index < options.samples; ++index) {
      Clock::duration decode{};
      const auto elapsed = session.key(index % 2 == 0 ? "<C-e>" : "<C-y>", &decode);

      if (elapsed) {
        line_scroll.add(*elapsed);
        line_decode.add(decode);
      }
    }

    for (std::size_t index = 0; index < options.samples / 4; ++index) {
      Clock::duration decode{};
      const auto elapsed = session.key(index % 2 == 0 ? "<C-d>" : "<C-u>", &decode);

      if (elapsed) {
        page_scroll.add(*elapsed);
        page_decode.add(decode);
      }
    }

    line_scroll.print("key to flush, one-line scroll");
    line_decode.print("  of which the runtime decodes");
    page_scroll.print("key to flush, half-page scroll");
    page_decode.print("  of which the runtime decodes");

    // The current directory: does Neovim tell the UI about a window's or a tab's own?
    session.editor().command("cd /");
    session.settle(std::chrono::seconds{3}, std::chrono::milliseconds{150});
    std::println("chdir after :cd /   -> {:?}", screen.directory());
    session.editor().command("lcd /tmp");
    session.settle(std::chrono::seconds{3}, std::chrono::milliseconds{150});
    std::println("chdir after :lcd /tmp -> {:?}", screen.directory());
    session.editor().command("tcd /usr");
    session.settle(std::chrono::seconds{3}, std::chrono::milliseconds{150});
    std::println("chdir after :tcd /usr -> {:?}", screen.directory());

    // The command line, when Neovim was asked for it as events.
    if (options.surfaces) {
      const auto floats = placed(screen, NvimPlacement::floating);

      session.key(":");
      session.settle(std::chrono::seconds{3}, std::chrono::milliseconds{300});
      std::println("cmdline visible={} first={:?} floats before={} after={}", screen.commandLine().visible, screen.commandLine().first, floats, placed(screen, NvimPlacement::floating));
      session.key("<Esc>");
      session.settle(std::chrono::seconds{3}, std::chrono::milliseconds{150});
    }

    // vim.ui.select and vim.ui.input, which the runtime takes over before the configuration
    // loads: does a later assignment, as a plugin would make, leave them the runtime's?
    session.editor().command("lua vim.ui.select = function() vim.g.telar_probe = 'replaced' end");
    session.editor().command("lua vim.ui.select({'uno', 'dos', 'tres'}, {prompt = 'Elige'}, function(choice, index) io.stderr:write('probe-select=' .. tostring(choice) .. '@' .. tostring(index) .. '\\n') end)");
    session.pump(std::chrono::seconds{3}, [&] {
      return session.editor().prompt().id != 0;
    });

    const auto& prompt = session.editor().prompt();

    std::println("vim.ui.select -> prompt id={} title={:?} choices={}", prompt.id, prompt.title.view(), prompt.choices.size());
    session.editor().answer({.id = prompt.id, .accepted = true, .index = 1});
    session.settle(std::chrono::seconds{3}, std::chrono::milliseconds{200});
    session.editor().command("lua io.stderr:write('probe-replaced=' .. tostring(vim.g.telar_probe) .. '\\n')");
    session.editor().command("lua vim.ui.input({prompt = 'Nombre', default = 'ana'}, function(text) io.stderr:write('probe-input=' .. tostring(text) .. '\\n') end)");
    session.pump(std::chrono::seconds{3}, [&] {
      return session.editor().prompt().id != 0;
    });
    std::println("vim.ui.input -> prompt id={} title={:?} initial={:?}", prompt.id, prompt.title.view(), prompt.initial.view());
    session.editor().answer({.id = prompt.id, .accepted = true, .text = "ana maria"});
    session.settle(std::chrono::seconds{3}, std::chrono::milliseconds{300});

    // A plugin writing to standard output, where the protocol travels.
    session.editor().command("lua io.stdout:write('telar-probe-pollution')");

    const bool survived = session.settle(std::chrono::seconds{3}, std::chrono::milliseconds{300}) || session.editor().state() == NvimState::attached;

    std::println("io.stdout:write from Lua -> editor {} ({})", survived && session.editor().state() == NvimState::attached ? "still attached" : "failed", session.editor().failure());
    session.stop();
    return 0;
  }

}

int main(int argc, char** argv) {
  Options options;
  const std::span<char*> arguments{argv, static_cast<std::size_t>(argc)};

  for (std::size_t index = 1; index < arguments.size(); ++index) {
    const std::string_view argument = arguments[index];
    const auto value = [&]() -> std::string_view {
      return index + 1 < arguments.size() ? std::string_view{arguments[++index]} : std::string_view{};
    };

    if (argument == "--nvim") {
      options.nvim = value();
    } else if (argument == "--file") {
      options.file = value();
    } else if (argument == "--cwd") {
      options.cwd = value();
    } else if (argument == "--samples") {
      options.samples = static_cast<std::size_t>(std::strtoul(std::string{value()}.c_str(), nullptr, 10));
    } else if (argument == "--clean") {
      options.clean = true;
    } else if (argument == "--surfaces") {
      options.surfaces = true;
    } else {
      std::println(stderr, "nvim-embed-probe: unknown argument {}", argument);
      return 2;
    }
  }

  try {
    return run(options);
  } catch (const std::exception& failure) {
    std::println(stderr, "nvim-embed-probe: {}", failure.what());
    return 1;
  }
}
