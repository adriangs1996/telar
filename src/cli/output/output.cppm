export module telar.cli.output;

import std;

import telar.base.memory.allocators;
import telar.base.text.json;
import telar.vocabulary;
import telar.base.ds;

// Interface: failure.cppm
export {
  namespace telar::runtime::cli {

    // A command that failed after its arguments parsed: `what()` is the text after
    // the family's prefix on stderr, `status` the exit status (2 for a missing
    // target, 3 for a timeout), and `code` the runtime's refusal, if any.
    class Failure : public std::runtime_error {
    public:
      explicit Failure(std::string_view message, int status = 1, ds::Option<FailureCode> code = ds::none);

      [[nodiscard]] int status() const noexcept;

      [[nodiscard]] ds::Option<FailureCode> code() const noexcept;

    private:
      int status_;
      ds::Option<FailureCode> code_;
    };

  }
}

// Interface: family.cppm
export {
  namespace telar::runtime::cli {

    // The first word of a command line that names a group of commands, as `worktree`
    // in `telar worktree create`. A word that is no family is a program to run in a
    // pane of a window.
    enum class Family : std::uint8_t {
      workspace,
      tab,
      pane,
      worktree,
      agent,
      exec,
      repository,
      project,
      file,
      machine,
      client,
      sidebar,
      workspace_list,
      layout,
      notification,
      command,
      config,
      completions,
      plugin,
      integration,
      hook,
      cli,
      gui,
      server,
      runtime,
      diagnostics,
      history,
      proxy,
      api,
      clipboard,
      render,
      count,
    };

    std::string_view familyName(Family family) noexcept;

    ds::Option<Family> parseFamily(std::string_view word) noexcept;

  }
}

// Interface: output.cppm
export {
  namespace telar::runtime::cli {

    // A command's stdout, built in memory and written once, so a failure halfway
    // prints nothing of the result.
    class Output {
    public:
      explicit Output(Memory& memory);

      Output& text(std::string_view value);

      // Instantiated for every standard integer type but the character ones.
      template <typename Integer>
      Output& number(Integer value);

      Output& boolean(bool value);

      Output& json(std::string_view value, JsonEscapes escapes = JsonEscapes::standard);

      void flush();

      ds::String<Memory> data;
    };

    extern template Output& Output::number<int>(int value);
    extern template Output& Output::number<long>(long value);
    extern template Output& Output::number<long long>(long long value);
    extern template Output& Output::number<unsigned char>(unsigned char value);
    extern template Output& Output::number<unsigned short>(unsigned short value);
    extern template Output& Output::number<unsigned int>(unsigned int value);
    extern template Output& Output::number<unsigned long>(unsigned long value);
    extern template Output& Output::number<unsigned long long>(unsigned long long value);

  }
}
