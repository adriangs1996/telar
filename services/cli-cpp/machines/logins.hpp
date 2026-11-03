#pragma once

#include "../control_session.hpp"
#include "../integration/files.hpp"
#include "config_sync.hpp"
#include "telar_base/text/utf8.hpp"
#include <sstream>

namespace telar::runtime::cli::machine {

struct LoginPlan {
  std::string title;
  std::vector<std::string> arguments;
  std::optional<std::string> environment;
  std::optional<std::string> keys;
  bool link = true;
  std::vector<std::string_view> hosts;
  std::optional<std::string> code_marker;
  std::optional<std::string> paste;
  std::string instructions;
};

inline std::optional<LoginPlan> planFor(std::string_view agent, const std::optional<std::string> &provider) {
  if (agent == "claude") {
    return LoginPlan{.title = "Log in to Claude Code", .arguments = {"auth", "login"}, .hosts = {"claude.com", "claude.ai", "platform.claude.com"}, .paste = "the code the browser shows", .instructions = "open the page, sign in, and paste the code it shows into this terminal"};
  }

  if (agent == "codex") {
    return LoginPlan{.title = "Log in to Codex", .arguments = {"login", "--device-auth"}, .hosts = {"auth.openai.com"}, .code_marker = "one-time code", .instructions = "open the page, sign in and enter the code"};
  }

  if (agent == "cursor") {
    return LoginPlan{.title = "Log in to Cursor Agent", .arguments = {"login"}, .environment = "NO_OPEN_BROWSER=1", .hosts = {"cursor.com"}, .instructions = "open the page and sign in"};
  }

  if (agent == "pi" && provider) {
    return LoginPlan{.title = "Log in to Pi", .keys = "/login", .link = false, .instructions = "choose the provider in the Pi pane there"};
  }

  if (agent == "opencode" && provider == "openai") {
    return LoginPlan{.title = "Log in to OpenCode", .arguments = {"auth", "login", "-p", "openai", "-m", "ChatGPT Pro/Plus (headless)"}, .hosts = {"auth.openai.com"}, .code_marker = "Enter code:", .instructions = "open the page, sign in and enter the code"};
  }

  return std::nullopt;
}

struct LoginPane {
  std::uint64_t workspace = 0;
  std::uint64_t tab = 0;
  std::uint64_t pane = 0;
  bool operator==(const LoginPane &) const = default;
};

struct LoginLink {
  std::string url;
  std::optional<std::string> code;
};

inline std::optional<LoginLink> findLoginLink(std::string_view text, const LoginPlan &plan) {
  std::string_view url;
  for (std::size_t start = 0;;) {
    const auto at = text.find("https://", start);
    if (at == std::string_view::npos) {
      return std::nullopt;
    }

    start = at + 1;
    auto end = at;
    while (end < text.size() && static_cast<unsigned char>(text[end]) > ' ' && static_cast<unsigned char>(text[end]) < 0x7f && !std::string_view{"\"'<>`"}.contains(text[end])) {
      ++end;
    }

    auto candidate = text.substr(at, end - at);
    while (candidate.size() > notification_link_scheme.size() && std::string_view{".,;:)]}"}.contains(candidate.back())) {
      candidate.remove_suffix(1);
    }

    try {
      if (candidate.size() > max_notification_link_bytes) {
        continue;
      }

      BodySchema<NotificationBody>::validate({.link = candidate});
    } catch (const std::exception &) {
      continue;
    }

    const auto host = filter::lower(notificationLinkHost(candidate));
    if (std::ranges::find(plan.hosts, host) != plan.hosts.end()) {
      url = candidate;
      break;
    }
  }

  LoginLink result{.url = std::string{url}};
  if (!plan.code_marker) {
    return result;
  }

  const auto marker = text.find(*plan.code_marker);
  if (marker == std::string_view::npos) {
    return result;
  }

  auto lines = text.substr(marker + plan.code_marker->size());
  for (;;) {
    const auto end = lines.find('\n');
    const auto line = filter::trim(lines.substr(0, end), " \t\r");
    const auto word = line.substr(0, line.find_first_of(" \t\r"));
    if (!word.empty() && !word.starts_with('(')) {
      result.code = word;
      return result;
    }

    if (end == std::string_view::npos) {
      return result;
    }

    lines.remove_prefix(end + 1);
  }
}

template <Allocator Memory>
class Logins {
  Memory &memory_;
  SetupReport &report_;
  const MachineProfile &profile_;
  const Platform &platform_;
  bool interactive_;
  static constexpr auto status_timeout = std::chrono::seconds{30};
  static constexpr auto link_timeout = std::chrono::seconds{60};
  static constexpr auto finish_timeout = std::chrono::minutes{15};
  static constexpr auto poll_interval = std::chrono::milliseconds{500};
  static constexpr auto status_interval = std::chrono::seconds{3};
  static constexpr std::string_view records = "$HOME/.local/state/telar/setup-logins";

  static JsonValue required(JsonValue value, std::string_view name) {
    const auto field = value.field(name);
    if (!field) {
      throw CommandError{"LoginPaneUnreadable"};
    }

    return *field;
  }

  static std::uint64_t number(JsonValue value) {
    const auto text = value.encoded();
    std::uint64_t result = 0;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
      throw CommandError{"LoginPaneUnreadable"};
    }

    return result;
  }

  std::string string(JsonValue value) {
    String<Memory> result{AllocatorRef<char, Memory>{memory_}};
    value.string(result);
    return std::string{result};
  }

  static LoginPane pane(JsonValue value) {
    return {number(required(value, "workspace_id")), number(required(value, "tab_id")), number(required(value, "pane_id"))};
  }

  std::string capture(const std::vector<std::string> &words, std::optional<std::string_view> input = std::nullopt) {
    std::string command = std::string{profile_.program().value_or("telar")} + " dispatch-argv";
    for (const auto &word : words) {
      command += " " + encode(word);
    }

    const auto output = input ? launch::captureBytes(ssh(memory_, profile_.destination(), command), *input, status_timeout) : launch::capture(ssh(memory_, profile_.destination(), command), -1, status_timeout);
    std::fwrite(output.err.data(), 1, output.err.size(), stderr);
    if (output.status != 0) {
      throw CommandError{"MachineCommandFailed"};
    }

    return whole(output);
  }

  launch::Output script(std::string_view bytes) {
    return runScript(memory_, profile_.destination(), bytes, status_timeout);
  }

  std::optional<std::string> command(const std::vector<std::string> &words, bool missing_pane) {
    std::string bytes = "exec " + launch::quote(profile_.program().value_or("telar"));
    for (const auto &word : words) {
      bytes += " " + launch::quote(word);
    }

    bytes += '\n';
    const auto output = script(bytes);
    auto diagnostic = std::string_view{output.err};
    while (diagnostic.ends_with('\n') || diagnostic.ends_with('\r')) {
      diagnostic.remove_suffix(1);
    }

    const bool missing = output.out.empty() && (missing_pane ? output.status == 2 && diagnostic == "telar pane: pane not found or its generation is stale" : output.status == 1 && (diagnostic == "telar tab: tab not found" || diagnostic == "telar tab: workspace not found"));
    if (missing) {
      return std::nullopt;
    }

    std::fwrite(output.err.data(), 1, output.err.size(), stderr);
    if (output.status == launch::ssh_failure) {
      throw CommandError{"SshFailed"};
    }

    if (output.status != 0) {
      throw CommandError{"MachineCommandFailed"};
    }

    return whole(output);
  }

  std::string recordPath(const std::string &agent) {
    return std::string{records} + "/" + agent;
  }

  void forget(const std::string &agent) {
    if (script("rm -f \"" + recordPath(agent) + "\"\n").status != 0) {
      throw CommandError{"LoginRecordUnwritable"};
    }
  }

  void remember(const std::string &agent, LoginPane pane) {
    const auto bytes = "umask 077 && mkdir -p \"" + std::string{records} + "\" && printf '%s\\n' '" + std::to_string(pane.workspace) + " " + std::to_string(pane.tab) + " " + std::to_string(pane.pane) + "' > \"" + recordPath(agent) + "\"\n";
    if (script(bytes).status != 0) {
      throw CommandError{"LoginRecordUnwritable"};
    }
  }

  std::optional<LoginPane> find(const std::string &agent, const std::string &title) {
    const auto output = script("cat \"" + recordPath(agent) + "\" 2>/dev/null || true\n");
    if (output.status != 0) {
      throw CommandError{"LoginRecordUnreadable"};
    }

    std::istringstream input{whole(output)};
    LoginPane noted;
    std::string extra;
    if (!(input >> noted.workspace >> noted.tab >> noted.pane) || input >> extra) {
      return std::nullopt;
    }

    const auto workspaces = capture({"workspace", "list", "--json"});
    bool named = false;
    JsonValue::parse(workspaces).eachElement([&](JsonValue value) {
      if (number(required(value, "workspace_id")) == noted.workspace && string(required(value, "name")) == title) {
        named = true;
      }
    });
    if (!named) {
      forget(agent);
      return std::nullopt;
    }

    const auto tab = command({"tab", "get", std::to_string(noted.tab), "--workspace", std::to_string(noted.workspace), "--json"}, false);
    if (tab) {
      const auto parsed = JsonValue::parse(*tab);
      if (number(required(parsed, "workspace_id")) != noted.workspace || number(required(parsed, "tab_id")) != noted.tab) {
        throw CommandError{"LoginPaneUnreadable"};
      }

      bool found = false;
      required(parsed, "panes").eachElement([&](JsonValue value) { found = found || number(required(value, "pane_id")) == noted.pane; });
      if (found) {
        return noted;
      }
    }

    forget(agent);
    return std::nullopt;
  }

  void closeTab(LoginPane pane) {
    const auto output = command({"tab", "close", std::to_string(pane.tab), "--workspace", std::to_string(pane.workspace), "--json"}, false);
    if (!output) {
      return;
    }

    const auto value = JsonValue::parse(*output);
    if (number(required(value, "workspace_id")) != pane.workspace || number(required(value, "tab_id")) != pane.tab || required(value, "closed").encoded() != "true") {
      throw CommandError{"LoginPaneUnreadable"};
    }
  }

  void close(const std::string &agent, LoginPane pane, const LoginPlan &plan) {
    const auto current = find(agent, plan.title);
    if (!current || *current != pane) {
      return;
    }

    closeTab(pane);
    forget(agent);
  }

  LoginPane open(const std::string &agent, const std::string &path, const LoginPlan &plan) {
    std::vector<std::string> words{"workspace", "create", "--directory", platform_.home, "--name", plan.title, "--columns", "1024", "--json", "--"};
    if (plan.environment) {
      words.push_back("/usr/bin/env");
      words.push_back(*plan.environment);
    }

    words.push_back(path);
    words.insert(words.end(), plan.arguments.begin(), plan.arguments.end());
    const auto output = capture(words);
    LoginPane created;
    try {
      created = pane(JsonValue::parse(output));
    } catch (const std::exception &) {
      throw CommandError{"LoginPaneUnreadable"};
    }

    try {
      remember(agent, created);
    } catch (...) {
      try {
        closeTab(created);
      } catch (const std::exception &) {
      }

      throw;
    }

    return created;
  }

  std::optional<std::string> provider(const std::string &agent) {
    if (agent != "pi" && agent != "opencode") {
      return std::nullopt;
    }

    const auto *home = std::getenv("HOME");
    if (!home) {
      return std::nullopt;
    }

    const auto root = localRoot(agent, home);
    const auto filenames = agent == "pi" ? std::vector<std::string>{"settings.json"} : std::vector<std::string>{"opencode.json", "opencode.jsonc"};
    for (const auto &name : filenames) {
      try {
        String<Memory> path{root + "/" + name, AllocatorRef<char, Memory>{memory_}};
        const auto bytes = integration::read(memory_, path, launch::output_limit);
        if (!bytes) {
          continue;
        }

        const auto plain = filter::stripJsonc(*bytes);
        const auto parsed = JsonValue::parse(plain);
        if (!parsed.encoded().starts_with('{')) {
          return std::nullopt;
        }

        const auto field = parsed.field(agent == "pi" ? "defaultProvider" : "model");
        if (!field || !field->encoded().starts_with('"')) {
          continue;
        }

        const auto value = string(*field);
        if (agent == "pi") {
          return value;
        }

        const auto slash = value.find('/');
        if (slash != std::string::npos) {
          return value.substr(0, slash);
        }
      } catch (const std::exception &) {
      }
    }

    return std::nullopt;
  }

  bool loggedIn(const std::string &agent, const std::string &path, const std::optional<std::string> &provider) {
    std::string check;
    if (agent == "claude") {
      check = "\"$agent\" auth status >/dev/null 2>&1";
    } else if (agent == "codex") {
      check = "\"$agent\" login status >/dev/null 2>&1";
    } else if (agent == "cursor") {
      check = "\"$agent\" status --format json 2>/dev/null | grep -Eq '\"status\": *\"authenticated\"|\"isAuthenticated\": *true'";
    } else if (agent == "pi") {
      check = "[ -n \"$provider\" ] && \"$agent\" auth check --provider \"$provider\" --no-refresh >/dev/null 2>&1";
    } else {
      check = "[ -n \"$provider\" ] && \"$agent\" auth list 2>/dev/null | grep -qi -- \"$provider\"";
    }

    const auto output = script(assign("agent", path) + assign("provider", provider.value_or("")) + check + "\n");
    if (output.status == launch::ssh_failure) {
      throw CommandError{"SshFailed"};
    }

    return output.status == 0;
  }

  struct Read {
    std::optional<int> exit_code;
    std::string text;
  };

  std::optional<Read> read(LoginPane pane) {
    const auto output = command({"pane", "read", std::to_string(pane.pane), "--lines", "80", "--json"}, true);
    if (!output) {
      return std::nullopt;
    }

    try {
      const auto value = JsonValue::parse(*output);
      if (number(required(value, "pane_id")) != pane.pane) {
        throw CommandError{"LoginPaneUnreadable"};
      }

      const auto exit = required(value, "exit_code").encoded();
      std::optional<int> code;
      if (exit != "null") {
        int parsed = 0;
        const auto result = std::from_chars(exit.data(), exit.data() + exit.size(), parsed);
        if (result.ec != std::errc{} || result.ptr != exit.data() + exit.size()) {
          throw CommandError{"LoginPaneUnreadable"};
        }

        code = parsed;
      }

      return Read{.exit_code = code, .text = string(required(value, "text"))};
    } catch (const std::exception &) {
      throw CommandError{"LoginPaneUnreadable"};
    }
  }

  std::optional<MachineLogin> ended(const std::string &agent, const std::string &path, const std::optional<std::string> &provider, std::optional<Read> read, LoginPane pane) {
    if (read && !read->exit_code) {
      return std::nullopt;
    }

    const auto logged_in = loggedIn(agent, path, provider);
    if (logged_in && (!read || read->exit_code == 0)) {
      return MachineLogin::done;
    }

    if (read && read->exit_code) {
      report_.note(Step::logins, agent + ": login command exited with " + std::to_string(*read->exit_code) + "; status is " + (logged_in ? "logged in" : "not logged in") + ". Read its diagnostic with pane read " + std::to_string(pane.pane) + " --json on " + std::string{profile_.label()} + ", then retry setup");
    } else {
      report_.note(Step::logins, agent + ": login pane disappeared before authentication completed; retry setup");
    }

    return MachineLogin::failed;
  }

  bool announce(const LoginPlan &plan, const LoginLink &found) {
    std::string body = "on " + std::string{profile_.label()} + ": " + plan.instructions;
    if (found.code) {
      body += ". Code: " + *found.code;
    }

    if (body.size() > max_notification_message_bytes && found.code) {
      body = "Code: " + *found.code + ", on " + std::string{profile_.label()} + ": " + plan.instructions;
    }

    try {
      const RuntimePaths paths{memory_, ServerOptions{}, ProcessEnvironment{}};
      ControlSession session{memory_, paths.socket.c_str()};
      session.receiveTimeout(static_cast<unsigned>(status_timeout.count()));
      const auto result = session.template exchange<NotificationShown>(ShowNotification{.notification = {.duration_ms = max_notification_duration_ms, .title = utf8Prefix(plan.title, max_notification_title_bytes), .message = utf8Prefix(body, max_notification_message_bytes), .link = found.url}});
      return result.delivered_clients != 0;
    } catch (const std::exception &) {
      return false;
    }
  }

  void send(LoginPane pane, std::string_view text) {
    capture({"pane", "send-keys", std::to_string(pane.pane), "--stdin", "--enter"}, text);
  }

  struct Request {
    std::string agent;
    std::string path;
    std::optional<std::string> provider;
    LoginPlan plan;
  };

  MachineLogin loginOne(const Request &request) {
    const auto &agent = request.agent;
    const auto &path = request.path;
    const auto &provider = request.provider;
    const auto &plan = request.plan;
    const auto existing = find(agent, plan.title);
    const auto pane = existing ? *existing : open(agent, path, plan);
    try {
      if (existing) {
        report_.progress(plan.title + " on " + std::string{profile_.label()} + ": the login setup started before is still open there");
      } else if (plan.keys) {
        send(pane, *plan.keys);
      }

      if (plan.link) {
        const auto deadline = std::chrono::steady_clock::now() + link_timeout;
        std::optional<LoginLink> found;
        while (std::chrono::steady_clock::now() < deadline) {
          const auto value = read(pane);
          if (const auto result = ended(agent, path, provider, value, pane)) {
            close(agent, pane, plan);
            return *result;
          }

          found = findLoginLink(value->text, plan);
          if (found && (!plan.code_marker || found->code)) {
            break;
          }

          found.reset();
          std::this_thread::sleep_for(poll_interval);
        }

        if (!found) {
          report_.progress(agent + ": no login link appeared in its pane on " + std::string{profile_.label()} + "; finish it there");
          return MachineLogin::pending;
        }

        report_.progress(plan.title + " on " + std::string{profile_.label()} + ": " + found->url);
        if (found->code) {
          report_.progress("one-time code: " + *found->code);
        }

        if (!announce(plan, *found)) {
          report_.progress("no window here took the notification; open the link above");
        }
      } else {
        announce(plan, {});
        report_.progress(plan.title + " on " + std::string{profile_.label()} + ": " + plan.instructions);
      }

      if (!interactive_) {
        if (const auto result = ended(agent, path, provider, read(pane), pane)) {
          close(agent, pane, plan);
          return *result;
        }

        return MachineLogin::pending;
      }

      if (plan.paste) {
        std::printf("Paste %s for %s (Enter to finish in the pane instead): ", plan.paste->c_str(), agent.c_str());
        std::fflush(stdout);
        std::string answer;
        if (std::getline(std::cin, answer) && answer.size() < max_notification_message_bytes * 8) {
          const auto text = filter::trim(answer, " \r\t");
          if (!text.empty()) {
            send(pane, text);
          }
        }
      }

      const auto deadline = std::chrono::steady_clock::now() + finish_timeout;
      auto status_at = std::chrono::steady_clock::now();
      while (std::chrono::steady_clock::now() < deadline) {
        if (const auto result = ended(agent, path, provider, read(pane), pane)) {
          close(agent, pane, plan);
          return *result;
        }

        if (std::chrono::steady_clock::now() >= status_at) {
          if (loggedIn(agent, path, provider)) {
            close(agent, pane, plan);
            return MachineLogin::done;
          }

          status_at = std::chrono::steady_clock::now() + status_interval;
        }

        std::this_thread::sleep_for(poll_interval);
      }

      report_.note(Step::logins, agent + ": authentication did not complete before the login timeout; retry setup");
      close(agent, pane, plan);
      return MachineLogin::failed;
    } catch (...) {
      try {
        close(agent, pane, plan);
      } catch (const std::exception &) {
      }

      throw;
    }
  }

public:
  Logins(Memory &memory, SetupReport &report, const MachineProfile &profile, const Platform &platform, bool interactive)
      : memory_(memory),
        report_(report),
        profile_(profile),
        platform_(platform),
        interactive_(interactive) {}

  void run(const std::set<std::string> &wanted, const std::string &profiles_path) {
    std::map<std::string, MachineLogin> results;
    bool started = false;
    for (const auto name : agent_names) {
      const std::string agent{name};
      if (!wanted.contains(agent) || !platform_.agents.contains(agent)) {
        continue;
      }

      const auto &path = platform_.agents.at(agent);
      const auto selected = provider(agent);
      bool logged_in = false;
      try {
        logged_in = loggedIn(agent, path, selected);
      } catch (const std::exception &error) {
        report_.note(Step::logins, agent + ": its login status could not be read there: " + error.what());
        results[agent] = MachineLogin::failed;
        continue;
      }

      const auto plan = planFor(agent, selected);
      if (logged_in) {
        try {
          if (plan) {
            if (const auto pane = find(agent, plan->title)) {
              close(agent, *pane, *plan);
            }
          }
        } catch (const std::exception &error) {
          report_.note(Step::logins, agent + ": its login cleanup failed: " + error.what());
          results[agent] = MachineLogin::failed;
          continue;
        }

        results[agent] = MachineLogin::done;
        report_.note(Step::logins, agent + ": logged in");
      } else if (!plan) {
        report_.note(Step::logins, agent + ": log in there yourself; setup has no browser login for " + selected.value_or("its provider"));
      } else {
        started = true;
        try {
          results[agent] = loginOne({agent, path, selected, *plan});
        } catch (const std::exception &error) {
          report_.note(Step::logins, agent + ": " + error.what());
          results[agent] = MachineLogin::failed;
        }

        if (results[agent] != MachineLogin::failed) {
          report_.note(Step::logins, agent + ": " + std::string{machine_login_names[static_cast<std::size_t>(results[agent])]});
        }
      }
    }

    try {
      if (!results.empty()) {
        update(memory_, profiles_path, [&](MachineProfiles &profiles) {
          for (const auto &[agent, result] : results) {
            const auto found = std::ranges::find(machine_agent_names, agent);
            profiles.recordLogin(profile_.label(), static_cast<MachineAgent>(found - machine_agent_names.begin()), result);
          }
        });
      }
    } catch (const std::exception &error) {
      const auto *text = describe(error.what());
      report_.note(Step::logins, std::string{"machines.json keeps the logins it had: "} + (text ? text : error.what()));
    }

    const bool failed = std::ranges::any_of(results, [](const auto &entry) { return entry.second == MachineLogin::failed; });
    const bool pending = std::ranges::any_of(results, [](const auto &entry) { return entry.second == MachineLogin::pending; });
    const auto status = failed ? Status::failed : results.empty() ? Status::skipped
                                              : pending           ? Status::pending
                                              : started           ? Status::changed
                                                                  : Status::ok;
    report_.end(Step::logins, status, failed ? "a login failed; see the notes" : results.empty() ? "no agent there to log in"
                                                                             : pending           ? "a login waits for you; run setup again to see it done"
                                                                             : started           ? "every started login finished"
                                                                                                 : "every agent there is logged in");
  }
};

}
