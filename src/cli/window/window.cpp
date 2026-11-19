module telar.cli.window;

import std;
import telar.tbc;

import telar.cli.runtime_observer;
import telar.cli.output;
import telar.platform.error;
import telar.platform.paths;
import telar.platform.process;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.wire.clients;
import telar.wire.editor;
import telar.wire.runtime;
import telar.platform.primitives;
import telar.cli.control_session;
import telar.client;
import telar.sys.posix;
import telar.sys.process;
import telar.tls;
import telar.base.text.utf8;
import telar.cli.command_limit;
import telar.base.ds;

namespace telar::runtime::cli::window {

  using Text = ds::String<Memory>;
  using Session = ControlSession;
  constexpr std::size_t memory_budget = 32 * 1024 * 1024;
  constexpr unsigned receive_timeout = 30;
  constexpr std::size_t maximum_command_text = 4096;

  constexpr const char* statusName(ClientCommandStatus status) {
    switch (status) {
    case ClientCommandStatus::applied:
      return "applied";
    case ClientCommandStatus::admitted:
      return "admitted";
    case ClientCommandStatus::failed:
      return "failed";
    case ClientCommandStatus::request:
      return "request";
    }

    return "request";
  }

  void number(Text& output, std::uint64_t value) {
    ds::Array<char, std::numeric_limits<std::uint64_t>::digits10 + 2> buffer;
    const char* const end = std::to_chars(buffer.dataMut(), buffer.dataMut() + buffer.size(), value).ptr;

    output.append(std::string_view{buffer.data(), end});
  }

  void signedNumber(Text& output, std::int64_t value) {
    ds::Array<char, std::numeric_limits<std::int64_t>::digits10 + 3> buffer;
    const char* const end = std::to_chars(buffer.dataMut(), buffer.dataMut() + buffer.size(), value).ptr;

    output.append(std::string_view{buffer.data(), end});
  }

  void descriptor(Text& output, const ClientDescriptor& entry, bool json) {
    if (json) {
      output.append("{\"id\":");
      number(output, entry.id);
      output.append(",\"generation\":");
      number(output, entry.generation);
      output.append(",\"identity\":");
      number(output, entry.identity);
      output.append(",\"attachments\":");
      number(output, entry.attachments);
      output.append(",\"last_input_pane\":");
      number(output, entry.last_input_pane);
      output.append(",\"last_input_sequence\":");
      number(output, entry.last_input_sequence);
      output.push('}');
    } else {
      number(output, entry.id);
      output.push('\t');
      number(output, entry.generation);
      output.push('\t');
      number(output, entry.identity);
      output.push('\t');
      number(output, entry.attachments);
      output.push('\t');
      number(output, entry.last_input_pane);
      output.push('\n');
    }
  }

  void clients(Session& session, const ClientOptions& options, Text& output) {
    const auto list = session.exchange<ClientList>(QueryClients{});

    if (options.action == ClientOptions::Action::list) {
      output.append(options.json ? "[" : "CLIENT\tGENERATION\tIDENTITY\tATTACHMENTS\tLAST INPUT PANE\n");
      bool first = true;

      for (const auto& entry : list.entries) {
        if (options.json && !first) {
          output.push(',');
        }

        descriptor(output, entry, options.json);
        first = false;
      }

      if (options.json) {
        output.append("]\n");
      }

      return;
    }

    for (const auto entry : list.entries) {
      if (entry.id != options.target) {
        continue;
      }

      if (options.action == ClientOptions::Action::detach) {
        session.exchange<RequestCompleted>(DetachClient{
            .client_id = entry.id,
            .client_generation = entry.generation,
        });

        if (options.json) {
          output.append("{\"id\":");
          number(output, entry.id);
          output.append(",\"generation\":");
          number(output, entry.generation);
          output.append(",\"detached\":true}\n");
        } else {
          output.append("client ");
          number(output, entry.id);
          output.append(" detached\n");
        }
      } else {
        descriptor(output, entry, options.json);
        if (options.json) {
          output.push('\n');
        }
      }

      return;
    }

    throw Failure{"ClientNotFound", 2};
  }

  tbc::view<ClientCommandResult, tbc::lt::a> exchangeCommand(tbc::view<Session&, tbc::lt::a> session, const ClientCommand& command) {
    const auto reply = session.exchange<ClientCommandResult>(RequestClientCommand{command});
    if (reply.route.id != command.route.id || reply.route.generation != command.route.generation || reply.action != command.action || reply.target_id != command.target_id || reply.status == ClientCommandStatus::request) {
      throw Failure{"unexpected reply from the runtime"};
    }

    return reply;
  }

  // Collect owned pages before printing: a concurrent reload must never mix generations.
  void plugins(Session& session, ClientCommand command, ClientCommandResult reply, Text& output) {
    ds::Vec<Text, Memory> entries{output.memory()};
    ds::Option<std::int64_t> generation;
    const std::int64_t limit = command.action == ClientAction::plugin_get ? 65 : 32;

    for (std::int64_t page_index = 0;; ++page_index) {
      if (page_index >= limit || reply.status != ClientCommandStatus::applied) {
        throw Failure{"InvalidPluginPage"};
      }

      const auto page = JsonValue::parse(reply.text);
      const auto version = page.field("generation");
      const auto items = page.field("entries");
      std::int64_t version_number = 0;

      if (!version || !items || !items->encoded().starts_with('[')) {
        throw Failure{"InvalidPluginPage"};
      }

      const auto encoded = version->encoded();
      const auto parsed = std::from_chars(encoded.data(), encoded.data() + encoded.size(), version_number);
      if (parsed.ec != std::errc{} || parsed.ptr != encoded.data() + encoded.size() || version_number <= 0) {
        throw Failure{"InvalidPluginPage"};
      }

      if (generation && *generation != version_number) {
        throw Failure{"StaleConfiguration"};
      }

      generation = version_number;
      std::size_t count = 0;

      items->eachElement([&](const JsonValue& item) {
        if (++count > 1) {
          throw Failure{"InvalidPluginPage"};
        }

        Text entry{output.memory()};

        appendJson(entry, item, false);
        entries.push(std::move(entry));
      });

      if (reply.value == -1) {
        break;
      }

      if (reply.value <= command.value || reply.value >= limit) {
        throw Failure{"InvalidPluginPage"};
      }

      command.value = reply.value;
      command.target_id = static_cast<std::uint64_t>(*generation);
      reply = exchangeCommand(session, command);
      if (reply.status == ClientCommandStatus::failed) {
        std::println(stderr, "telar: {:.{}}", reply.text.data(), static_cast<int>(reply.text.size()));
        throw Failure{"PluginQueryFailed"};
      }
    }

    if (command.action == ClientAction::plugin_get) {
      if (entries.empty() || !entries.front().view().starts_with('{')) {
        throw Failure{"InvalidPluginPage"};
      }

      output.assign(entries.front());
      output.truncate(output.size() - 1);
      output.append(output.size() == 1 ? "\"actions\":[" : ",\"actions\":[");
      for (std::size_t index = 1; index < entries.size(); ++index) {
        if (!entries[index].view().starts_with('"')) {
          throw Failure{"InvalidPluginPage"};
        }

        if (index > 1) {
          output.push(',');
        }

        output.append(entries[index]);
      }

      output.append("]}\n");
    } else {
      output.push('[');
      for (std::size_t index = 0; index < entries.size(); ++index) {
        if (index != 0) {
          output.push(',');
        }

        output.append(entries[index]);
      }

      output.append("]\n");
    }
  }

  int routed(Session& session, const RoutedOptions& options, Text& output) {
    const auto list = session.exchange<ClientList>(QueryClients{});
    const auto route = std::ranges::find(list.entries, options.client_id, &ClientDescriptor::id);
    if (route == list.entries.end()) {
      throw Failure{"ClientNotFound", 2};
    }

    if (options.text.size() > maximum_command_text) {
      throw Failure{"InvalidClientCommandText"};
    }

    try {
      validateUtf8(options.text);
    } catch (const EncodingError&) {
      throw Failure{"InvalidClientCommandText"};
    }

    const ClientCommand command{
        .route = {.id = route->id, .generation = route->generation},
        .action = options.action,
        .target_id = options.target_id,
        .value = options.value,
        .text = options.text,
    };

    const auto reply = exchangeCommand(session, command);
    if (reply.status == ClientCommandStatus::failed) {
      std::println(stderr, "telar: {:.{}}", reply.text.data(), static_cast<int>(reply.text.size()));
      return 1;
    }

    if (reply.action == ClientAction::plugin_list || reply.action == ClientAction::plugin_get) {
      // The first page leaves the session's storage, which answering the next one reuses.
      const Text first{output.memory(), reply.text};
      auto page = reply;

      page.text = first;
      plugins(session, command, page, output);
    } else if (reply.action == ClientAction::config_show) {
      appendJson(output, JsonValue::parse(reply.text), !options.json);
      output.push('\n');
    } else if (reply.action == ClientAction::layout_get) {
      if (options.json) {
        output.append(R"({"encoding":"telar-layout-hex","data":)");
        appendJsonText(output, reply.text, JsonEscapes::standard);
        output.push('}');
      } else {
        output.append(reply.text);
      }

      output.push('\n');
    } else if (reply.action == ClientAction::sidebar_get) {
      if (options.json) {
        output.append(reply.text == "visible" ? R"({"visible":true,"width":)" : R"({"visible":false,"width":)");
        signedNumber(output, reply.value);
        output.append("}\n");
      } else {
        output.append(reply.text);
        output.push(' ');
        signedNumber(output, reply.value);
        output.append(" columns\n");
      }
    } else if (options.json) {
      output.append("{\"client_id\":");
      number(output, reply.route.id);
      output.append(",\"client_generation\":");
      number(output, reply.route.generation);
      output.append(",\"action\":");
      appendJsonText(output, clientActionName(reply.action), JsonEscapes::standard);
      output.append(",\"status\":");
      appendJsonText(output, statusName(reply.status), JsonEscapes::standard);
      output.append(",\"target_id\":");
      number(output, reply.target_id);
      output.append(",\"value\":");
      signedNumber(output, reply.value);
      output.append(",\"text\":");
      appendJsonText(output, reply.text, JsonEscapes::standard);
      output.append("}\n");
    } else {
      output.append(clientActionName(reply.action));
      output.append(": ");
      output.append(statusName(reply.status));
      if (!reply.text.empty()) {
        output.push(' ');
        output.append(reply.text);
      }

      output.push('\n');
    }

    return 0;
  }

  int suggest(Session& session, const SuggestionOptions& options, Text& output) {
    const auto reply = session.exchange<CommandSuggestion>(SuggestCommand{
        .pane_id = options.pane,
        .text = options.text,
    });

    constexpr ds::Array statuses{"ready", "unavailable", "timeout", "failed"};
    const auto* const status = statuses.at(static_cast<std::size_t>(reply.status));

    if (options.json) {
      output.append("{\"status\":");
      appendJsonText(output, status, JsonEscapes::standard);
      output.append(",\"command\":");
      appendJsonText(output, reply.text, JsonEscapes::standard);
      output.append("}\n");
    } else if (reply.status == SuggestionStatus::ready) {
      output.append(reply.text);
      output.push('\n');
    } else {
      std::println(stderr, "telar command suggest: {}", status);
    }

    return reply.status == SuggestionStatus::ready ? 0 : reply.status == SuggestionStatus::timeout ? 3
                                                                                                   : 1;
  }

  std::string_view utf8Prefix(std::string_view text, std::size_t maximum) {
    if (text.size() <= maximum) {
      return text;
    }

    while (maximum != 0 && (static_cast<unsigned char>(text[maximum]) & 0xc0) == 0x80) {
      --maximum;
    }

    return text.substr(0, maximum);
  }

  int notify(Session& session, NotificationBody notification) {
    ds::Option<LimitReach> reach;

    if (notification.title.size() > max_notification_title_bytes) {
      reach = LimitReach{
          .name = "notifications.max_title_bytes",
          .noun = "bytes",
          .value = max_notification_title_bytes,
          .requested = notification.title.size(),
      };

      notification.title = utf8Prefix(notification.title, max_notification_title_bytes);
    }

    if (notification.message.size() > max_notification_message_bytes) {
      reach = LimitReach{
          .name = "notifications.max_message_bytes",
          .noun = "bytes",
          .value = max_notification_message_bytes,
          .requested = notification.message.size(),
      };

      notification.message = utf8Prefix(notification.message, max_notification_message_bytes);
    }

    for (const auto text : {notification.title, notification.message}) {
      try {
        validateUtf8(text);
      } catch (const EncodingError&) {
        throw Failure{"InvalidUtf8"};
      }

      if (std::ranges::any_of(text, [](unsigned char byte) {
            return byte < 0x20 || byte == 0x7f;
          })) {
        throw Failure{"InvalidNotificationText"};
      }
    }

    try {
      BodySchema<NotificationBody>::validate(notification);
    } catch (const EncodingError&) {
      throw Failure{"InvalidNotificationLink"};
    }

    if (notification.link.size() > max_notification_link_bytes) {
      throw Failure{"InvalidNotificationLink"};
    }

    const auto shown = session.exchange<NotificationShown>(ShowNotification{
        .notification = notification,
    });
    if (shown.delivered_clients == 0) {
      throw Failure{"NoNotificationClients"};
    }

    if (reach) {
      try {
        session.send(ReportLimit{
            .reach = *reach,
            .hits = 1,
        });
      } catch (...) {
      }

      std::println(stderr, "telar: Limit reached: {:.{}}: {} bytes; limit {}\nerror: NotificationTextTooLong", reach->name.data(), static_cast<int>(reach->name.size()), static_cast<unsigned long long>(*reach->requested), static_cast<unsigned long long>(reach->value));
      return 1;
    }

    return 0;
  }

  const char* socketOption(const RoutedOptions& options) {
    return options.socket;
  }

  const char* socketOption(const ClientOptions& options) {
    return options.socket;
  }

  const char* socketOption(const SuggestionOptions& options) {
    return options.socket;
  }

  const char* socketOption(const NotificationOptions& options) {
    return options.socket;
  }

  template <typename Options, typename Execute>
  int connected(const Options& options, const char* prefix, Execute execute) {
    try {
      SystemAllocator system;
      BudgetAllocator budget{system, memory_budget};
      MemoryAdapter budget_memory{budget};
      Memory& memory = budget_memory;
      ServerOptions server;

      if (const auto socket = socketOption(options)) {
        server.socket = socket;
      }

      const RuntimePaths paths{memory, server, process_environment};
      Session session{memory, paths.socket.data()};

      session.receiveTimeout(receive_timeout);
      Text output{memory};
      const auto result = execute(session, output);

      if (std::fwrite(output.data(), 1, output.size(), stdout) != output.size()) {
        throw Failure{"WriteFailed"};
      }

      return result;
    } catch (const Failure& error) {
      if constexpr (std::is_same_v<Options, NotificationOptions>) {
        const auto* const message = std::string_view{error.what()} == "NoNotificationClients" ? "no UI client is connected" : error.what();

        std::println(stderr, "{}{}\nerror: {}", prefix, message, error.what());
      } else {
        std::println(stderr, "{}{}", prefix, error.what());
      }

      return error.status();
    } catch (const ControlFailure& error) {
      std::println(stderr, "{}{}", prefix, error.what());
    } catch (const SystemError& error) {
      const bool timeout = error.code() == EAGAIN || error.code() == ETIMEDOUT;
      const char* description = timeout ? "RuntimeTimeout" : error.code() == ENOENT || error.code() == ECONNREFUSED ? sys::errorName(error.code())
                                                                                                                    : error.what();

      if constexpr (std::is_same_v<Options, NotificationOptions>) {
        if (error.code() == ENOENT || error.code() == ECONNREFUSED) {
          std::println(stderr, "{}runtime is not running\nerror: RuntimeNotRunning", prefix);
        } else {
          std::println(stderr, "{}{}\nerror: {}", prefix, description, description);
        }

        return 1;
      }

      std::println(stderr, "{}{}", prefix, description);
      return timeout ? 3 : 1;
    } catch (const SocketError& error) {
      const std::string_view message = error.what();
      const bool timeout = message == "Runtime receive timed out";
      const auto* const description = timeout ? "RuntimeTimeout" : message == "Runtime closed the connection" ? "ConnectionClosed"
                                                                                                              : error.what();

      std::println(stderr, "{}{}", prefix, description);
      return timeout ? 3 : 1;
    } catch (const EncodingError&) {
      std::println(stderr, "{}unexpected reply from the runtime", prefix);
    } catch (const std::exception& error) {
      std::println(stderr, "{}{}", prefix, error.what());
    }

    return 1;
  }

}

namespace telar::runtime::cli {

  int runRouted(const RoutedOptions& options) {
    using namespace window;

    return connected(options, "telar: ", [&](Session& session, Text& output) {
      return routed(session, options, output);
    });
  }

  int runWindow(Family family, std::span<char* const> words) {
    using namespace window;

    if (family == Family::client) {
      const auto options = ClientOptions::parse(words);

      return connected(options, "telar client: ", [&](Session& session, Text& output) {
        clients(session, options, output);
        return 0;
      });
    }

    if (family == Family::command) {
      auto options = SuggestionOptions::parse(words);
      if (options.current) {
        try {
          const auto current = process_environment.lookup("TELAR_PANE_ID");

          if (current.empty()) {
            throw Failure{"MissingCurrentIdentity"};
          }

          options.pane = positive(current, "InvalidIdentity");
        } catch (const std::exception& error) {
          std::println(stderr, "telar command suggest: {}", error.what());
          return 1;
        }
      }

      return connected(options, "telar command suggest: ", [&](Session& session, Text& output) {
        return suggest(session, options, output);
      });
    }

    if (family == Family::notification) {
      const auto options = NotificationOptions::parse(words);

      return connected(options, "telar notification: ", [&](Session& session, Text&) {
        return notify(session, options.notification);
      });
    }

    if (family == Family::config) {
      window::ConfigCheckOptions::parse(words);
      const ExecutablePath helper{"telar-config-check"};
      // The options parsed: at most a path and a profile, so the arguments fit.
      ds::Array<char*, 8> arguments{};
      if (words.size() + 2 > arguments.size()) {
        throw std::invalid_argument{"TooManyConfigArguments"};
      }

      // execv takes char* const[] for C's sake and never writes through them.
      arguments.atMut(0) = const_cast<char*>(helper.c_str());
      std::ranges::copy(words, arguments.viewMut().begin() + 1);
      ::execv(helper.c_str(), arguments.dataMut());
      throw SystemError{"Execute telar-config-check"};
    }

    throw std::invalid_argument{words.empty() ? "MissingClientAction" : "UnknownClientAction"};
  }

}
