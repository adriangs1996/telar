export module telar.cli.runtime_observer;

import std;

import telar.cli.command_limit;

import telar.base.text;
import telar.platform.paths;
import telar.base.memory.allocators;

// Interface: api_schema.cppm
export {
  namespace telar::runtime::cli::api {

    int run(Arguments words);

  }
}

// Interface: runtime_clipboard.cppm
export {
  namespace telar::runtime::cli::runtime_clipboard {

    struct Options {
      std::optional<std::string_view> socket;

      static Options parse(Arguments words);
    };

    int run(Memory& memory, const Options& options);

  }
}

// Interface: runtime_options.cppm
export {
  namespace telar::runtime::cli {

    struct RuntimeOptions {
      enum class Action {
        status,
        metrics,
        watch,
      };
      Action action;
      bool json = false;
      bool proxy_only = false;
      std::optional<std::uint32_t> count = std::nullopt;
      std::optional<std::string_view> socket = std::nullopt;

      static RuntimeOptions parse(Arguments words);
    };

  }
}

// Interface: runtime_observer.cppm
export {
  namespace telar::runtime::cli {

    int runRuntime(Memory& memory, const RuntimeOptions& options);

  }
}
