module telar.base.history.secrets;

import std;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // The bytes a token may hold after its marker.
    enum class Alphabet : std::uint8_t {
      // [A-Z0-9]
      upper,
      // [A-Z0-9-]
      upper_dashed,
      // [A-Za-z0-9]
      alphanumeric,
      // [A-Za-z0-9_]
      word,
      // [A-Za-z0-9_-]
      url,
      // [A-Za-z0-9-]
      dashed,
      // [A-Za-z0-9_.-]
      dotted,
      // [A-Za-z0-9+/=_-], standard and URL-safe base64 alike
      base64,
      // [a-f0-9]
      hex,
    };

    struct TokenRule {
      std::string_view marker;
      Alphabet alphabet;
      std::size_t minimum;
    };

    // A provider's key, by the marker it begins with: the vendors atuin's secret filter knows and
    // those gitleaks names by a fixed prefix. The rules of one first byte stay together, which is
    // how a byte finds its rules, and a marker that another one begins with comes after it, so
    // `sk-ant-` is read before `sk-`. The minimums are those of the keys the providers issue, or
    // lower where a key of an older format is shorter. A provider whose keys have no marker, as a
    // bare 40-byte Cloudflare token, is left to the names its keys are assigned to.
    constexpr ds::Array token_rules{
        // AWS access keys, Google API keys, age, 1Password secret keys, Atlassian API tokens.
        TokenRule{.marker = "AKIA", .alphabet = Alphabet::upper, .minimum = 16},
        TokenRule{.marker = "ASIA", .alphabet = Alphabet::upper, .minimum = 16},
        TokenRule{.marker = "AIza", .alphabet = Alphabet::url, .minimum = 35},
        TokenRule{.marker = "AGE-SECRET-KEY-1", .alphabet = Alphabet::upper, .minimum = 58},
        TokenRule{.marker = "A3-", .alphabet = Alphabet::upper_dashed, .minimum = 34},
        TokenRule{.marker = "ATATT3", .alphabet = Alphabet::base64, .minimum = 100},
        // Contentful, CircleCI, Clojars.
        TokenRule{.marker = "CFPAT-", .alphabet = Alphabet::url, .minimum = 43},
        TokenRule{.marker = "CCIPAT_", .alphabet = Alphabet::url, .minimum = 40},
        TokenRule{.marker = "CLOJARS_", .alphabet = Alphabet::alphanumeric, .minimum = 60},
        // Google OAuth client secrets.
        TokenRule{.marker = "GOCSPX-", .alphabet = Alphabet::url, .minimum = 28},
        // Heroku.
        TokenRule{.marker = "HRKU-AA", .alphabet = Alphabet::url, .minimum = 58},
        // Alibaba Cloud access keys.
        TokenRule{.marker = "LTAI", .alphabet = Alphabet::alphanumeric, .minimum = 20},
        // New Relic user keys.
        TokenRule{.marker = "NRAK-", .alphabet = Alphabet::upper, .minimum = 27},
        // Postman.
        TokenRule{.marker = "PMAK-", .alphabet = Alphabet::dashed, .minimum = 59},
        // SendGrid: `SG.`, 22 bytes, a dot, 43 bytes.
        TokenRule{.marker = "SG.", .alphabet = Alphabet::dotted, .minimum = 66},
        // Hugging Face organization tokens.
        TokenRule{.marker = "api_org_", .alphabet = Alphabet::alphanumeric, .minimum = 30},
        // Buildkite.
        TokenRule{.marker = "bkua_", .alphabet = Alphabet::hex, .minimum = 40},
        // Cerebras.
        TokenRule{.marker = "csk-", .alphabet = Alphabet::alphanumeric, .minimum = 40},
        // DigitalOcean, Docker Hub, Databricks, Doppler, Dynatrace.
        TokenRule{.marker = "dop_v1_", .alphabet = Alphabet::hex, .minimum = 64},
        TokenRule{.marker = "doo_v1_", .alphabet = Alphabet::hex, .minimum = 64},
        TokenRule{.marker = "dor_v1_", .alphabet = Alphabet::hex, .minimum = 64},
        TokenRule{.marker = "dckr_pat_", .alphabet = Alphabet::url, .minimum = 27},
        TokenRule{.marker = "dckr_oat_", .alphabet = Alphabet::url, .minimum = 27},
        TokenRule{.marker = "dapi", .alphabet = Alphabet::hex, .minimum = 32},
        TokenRule{.marker = "dp.pt.", .alphabet = Alphabet::alphanumeric, .minimum = 40},
        TokenRule{.marker = "dp.st.", .alphabet = Alphabet::alphanumeric, .minimum = 40},
        TokenRule{.marker = "dp.ct.", .alphabet = Alphabet::alphanumeric, .minimum = 40},
        TokenRule{.marker = "dp.sa.", .alphabet = Alphabet::alphanumeric, .minimum = 40},
        TokenRule{.marker = "dp.scim.", .alphabet = Alphabet::alphanumeric, .minimum = 40},
        TokenRule{.marker = "dp.audit.", .alphabet = Alphabet::alphanumeric, .minimum = 40},
        TokenRule{.marker = "dt0c01.", .alphabet = Alphabet::dotted, .minimum = 80},
        // Fly.io, Frame.io, Fireworks.
        TokenRule{.marker = "fo1_", .alphabet = Alphabet::url, .minimum = 40},
        TokenRule{.marker = "fm1a_", .alphabet = Alphabet::base64, .minimum = 50},
        TokenRule{.marker = "fm1r_", .alphabet = Alphabet::base64, .minimum = 50},
        TokenRule{.marker = "fm2_", .alphabet = Alphabet::base64, .minimum = 50},
        TokenRule{.marker = "fio-u-", .alphabet = Alphabet::url, .minimum = 64},
        TokenRule{.marker = "fw_", .alphabet = Alphabet::alphanumeric, .minimum = 20},
        // GitHub, GitLab, Grafana, Groq.
        TokenRule{.marker = "ghp_", .alphabet = Alphabet::alphanumeric, .minimum = 20},
        TokenRule{.marker = "gho_", .alphabet = Alphabet::alphanumeric, .minimum = 20},
        TokenRule{.marker = "ghu_", .alphabet = Alphabet::alphanumeric, .minimum = 20},
        TokenRule{.marker = "ghs_", .alphabet = Alphabet::alphanumeric, .minimum = 20},
        TokenRule{.marker = "ghr_", .alphabet = Alphabet::word, .minimum = 20},
        TokenRule{.marker = "github_pat_", .alphabet = Alphabet::word, .minimum = 20},
        TokenRule{.marker = "glpat-", .alphabet = Alphabet::url, .minimum = 20},
        TokenRule{.marker = "glptt-", .alphabet = Alphabet::hex, .minimum = 40},
        TokenRule{.marker = "glrt-", .alphabet = Alphabet::url, .minimum = 20},
        TokenRule{.marker = "gldt-", .alphabet = Alphabet::url, .minimum = 20},
        TokenRule{.marker = "gloas-", .alphabet = Alphabet::url, .minimum = 32},
        TokenRule{.marker = "glsa_", .alphabet = Alphabet::word, .minimum = 40},
        TokenRule{.marker = "glc_", .alphabet = Alphabet::base64, .minimum = 32},
        TokenRule{.marker = "gsk_", .alphabet = Alphabet::alphanumeric, .minimum = 32},
        // Vault, Hugging Face.
        TokenRule{.marker = "hvs.", .alphabet = Alphabet::url, .minimum = 24},
        TokenRule{.marker = "hvb.", .alphabet = Alphabet::url, .minimum = 24},
        TokenRule{.marker = "hf_", .alphabet = Alphabet::alphanumeric, .minimum = 30},
        // Mailgun.
        TokenRule{.marker = "key-", .alphabet = Alphabet::hex, .minimum = 32},
        // Linear, LangSmith.
        TokenRule{.marker = "lin_api_", .alphabet = Alphabet::alphanumeric, .minimum = 40},
        TokenRule{.marker = "lsv2_pt_", .alphabet = Alphabet::word, .minimum = 40},
        TokenRule{.marker = "lsv2_sk_", .alphabet = Alphabet::word, .minimum = 40},
        // npm, Netlify, Notion, Neon.
        TokenRule{.marker = "npm_", .alphabet = Alphabet::alphanumeric, .minimum = 30},
        TokenRule{.marker = "nfp_", .alphabet = Alphabet::word, .minimum = 30},
        TokenRule{.marker = "ntn_", .alphabet = Alphabet::alphanumeric, .minimum = 40},
        TokenRule{.marker = "napi_", .alphabet = Alphabet::alphanumeric, .minimum = 40},
        // 1Password service accounts: `ops_` and a base64 JSON object.
        TokenRule{.marker = "ops_eyJ", .alphabet = Alphabet::base64, .minimum = 100},
        // Perplexity, PyPI and TestPyPI, PlanetScale, Pulumi, Prefect, Pinecone, Adobe.
        TokenRule{.marker = "pplx-", .alphabet = Alphabet::alphanumeric, .minimum = 48},
        TokenRule{.marker = "pypi-AgEIcHlwaS5vcmc", .alphabet = Alphabet::url, .minimum = 50},
        TokenRule{.marker = "pypi-AgENdGVzdC5weXBpLm9yZw", .alphabet = Alphabet::url, .minimum = 50},
        TokenRule{.marker = "pscale_tkn_", .alphabet = Alphabet::url, .minimum = 32},
        TokenRule{.marker = "pscale_pw_", .alphabet = Alphabet::url, .minimum = 32},
        TokenRule{.marker = "pscale_oauth_", .alphabet = Alphabet::url, .minimum = 32},
        TokenRule{.marker = "pul-", .alphabet = Alphabet::hex, .minimum = 40},
        TokenRule{.marker = "pnu_", .alphabet = Alphabet::alphanumeric, .minimum = 36},
        TokenRule{.marker = "pcsk_", .alphabet = Alphabet::word, .minimum = 50},
        TokenRule{.marker = "p8e-", .alphabet = Alphabet::url, .minimum = 32},
        // Stripe's restricted keys, RubyGems, Replicate, Render, ReadMe.
        TokenRule{.marker = "rk_live_", .alphabet = Alphabet::alphanumeric, .minimum = 12},
        TokenRule{.marker = "rk_test_", .alphabet = Alphabet::alphanumeric, .minimum = 12},
        TokenRule{.marker = "rubygems_", .alphabet = Alphabet::hex, .minimum = 48},
        TokenRule{.marker = "r8_", .alphabet = Alphabet::alphanumeric, .minimum = 37},
        TokenRule{.marker = "rnd_", .alphabet = Alphabet::alphanumeric, .minimum = 30},
        TokenRule{.marker = "rdme_", .alphabet = Alphabet::alphanumeric, .minimum = 60},
        // Stripe, ElevenLabs, Anthropic, OpenAI, OpenRouter, Langfuse, Sentry, Shopify, Supabase,
        // Sourcegraph, Shippo, Notion's older keys, Square, Mapbox.
        TokenRule{.marker = "sk_live_", .alphabet = Alphabet::alphanumeric, .minimum = 12},
        TokenRule{.marker = "sk_test_", .alphabet = Alphabet::alphanumeric, .minimum = 12},
        TokenRule{.marker = "sk_", .alphabet = Alphabet::hex, .minimum = 48},
        TokenRule{.marker = "sk-ant-", .alphabet = Alphabet::url, .minimum = 32},
        TokenRule{.marker = "sk-proj-", .alphabet = Alphabet::url, .minimum = 32},
        TokenRule{.marker = "sk-admin-", .alphabet = Alphabet::url, .minimum = 32},
        TokenRule{.marker = "sk-svcacct-", .alphabet = Alphabet::url, .minimum = 32},
        TokenRule{.marker = "sk-or-v1-", .alphabet = Alphabet::hex, .minimum = 32},
        TokenRule{.marker = "sk-lf-", .alphabet = Alphabet::dashed, .minimum = 32},
        TokenRule{.marker = "sk-", .alphabet = Alphabet::alphanumeric, .minimum = 32},
        TokenRule{.marker = "sntrys_", .alphabet = Alphabet::base64, .minimum = 50},
        TokenRule{.marker = "sntryu_", .alphabet = Alphabet::hex, .minimum = 64},
        TokenRule{.marker = "shpat_", .alphabet = Alphabet::alphanumeric, .minimum = 32},
        TokenRule{.marker = "shpca_", .alphabet = Alphabet::alphanumeric, .minimum = 32},
        TokenRule{.marker = "shppa_", .alphabet = Alphabet::alphanumeric, .minimum = 32},
        TokenRule{.marker = "shpss_", .alphabet = Alphabet::alphanumeric, .minimum = 32},
        TokenRule{.marker = "sbp_", .alphabet = Alphabet::hex, .minimum = 40},
        TokenRule{.marker = "sb_secret_", .alphabet = Alphabet::url, .minimum = 20},
        TokenRule{.marker = "sgp_", .alphabet = Alphabet::word, .minimum = 40},
        TokenRule{.marker = "shippo_live_", .alphabet = Alphabet::hex, .minimum = 40},
        TokenRule{.marker = "shippo_test_", .alphabet = Alphabet::hex, .minimum = 40},
        TokenRule{.marker = "secret_", .alphabet = Alphabet::alphanumeric, .minimum = 43},
        TokenRule{.marker = "sq0atp-", .alphabet = Alphabet::url, .minimum = 22},
        TokenRule{.marker = "sq0csp-", .alphabet = Alphabet::url, .minimum = 40},
        TokenRule{.marker = "sk.eyJ", .alphabet = Alphabet::dotted, .minimum = 80},
        // Tailscale, Typeform, Tavily, Scalingo.
        TokenRule{.marker = "tskey-", .alphabet = Alphabet::dashed, .minimum = 20},
        TokenRule{.marker = "tfp_", .alphabet = Alphabet::url, .minimum = 40},
        TokenRule{.marker = "tvly-", .alphabet = Alphabet::url, .minimum = 30},
        TokenRule{.marker = "tk-us-", .alphabet = Alphabet::url, .minimum = 40},
        // Cloudflare origin CA keys.
        TokenRule{.marker = "v1.0-", .alphabet = Alphabet::dashed, .minimum = 150},
        // Stripe webhook secrets.
        TokenRule{.marker = "whsec_", .alphabet = Alphabet::alphanumeric, .minimum = 32},
        // Slack, xAI.
        TokenRule{.marker = "xoxb-", .alphabet = Alphabet::dashed, .minimum = 10},
        TokenRule{.marker = "xoxp-", .alphabet = Alphabet::dashed, .minimum = 10},
        TokenRule{.marker = "xoxa-", .alphabet = Alphabet::dashed, .minimum = 10},
        TokenRule{.marker = "xoxr-", .alphabet = Alphabet::dashed, .minimum = 10},
        TokenRule{.marker = "xoxs-", .alphabet = Alphabet::dashed, .minimum = 10},
        TokenRule{.marker = "xoxe-", .alphabet = Alphabet::dashed, .minimum = 10},
        TokenRule{.marker = "xapp-", .alphabet = Alphabet::dashed, .minimum = 10},
        TokenRule{.marker = "xai-", .alphabet = Alphabet::alphanumeric, .minimum = 32},
    };

    // The rules a byte begins, as a range of token_rules.
    struct RuleRange {
      std::uint8_t begin = 0;
      std::uint8_t end = 0;
    };

    constexpr ds::Array<RuleRange, 256> rules_by_byte = [] {
      static_assert(token_rules.size() <= std::numeric_limits<std::uint8_t>::max());
      ds::Array<RuleRange, 256> ranges{};

      for (std::size_t index = 0; index < token_rules.size(); ++index) {
        auto& range = ranges.atMut(static_cast<unsigned char>(token_rules[index].marker.front()));

        if (range.begin == range.end) {
          range = {.begin = static_cast<std::uint8_t>(index), .end = static_cast<std::uint8_t>(index)};
        }

        range.end = static_cast<std::uint8_t>(index + 1);
      }

      return ranges;
    }();

    // The rules of one byte are together, and no marker is read after a shorter one it begins with.
    constexpr bool rulesInOrder() {
      for (std::size_t index = 0; index < token_rules.size(); ++index) {
        const auto first = token_rules[index].marker.front();
        const auto range = rules_by_byte[static_cast<unsigned char>(first)];

        for (std::size_t other = range.begin; other < range.end; ++other) {
          if (token_rules[other].marker.front() != first) {
            return false;
          }
        }

        for (std::size_t later = index + 1; later < token_rules.size(); ++later) {
          if (token_rules[later].marker.starts_with(token_rules[index].marker)) {
            return false;
          }
        }
      }

      return true;
    }

    static_assert(rulesInOrder());

    // The names whose value is a secret, by how they end, ignoring case: `AWS_SECRET_ACCESS_KEY`,
    // `GITHUB_TOKEN`, `DB_PASSWORD`, `--password`, `"client_secret"`.
    constexpr ds::Array<std::string_view, 11> secret_names{
        "password",
        "passwd",
        "passphrase",
        "token",
        "secret",
        "api_key",
        "apikey",
        "access_key",
        "secret_key",
        "private_key",
        "accountkey",
    };

    constexpr std::size_t maximum_name_bytes = 64;
    constexpr std::string_view pem_begin = "-----BEGIN ";
    constexpr std::string_view pem_dashes = "-----";
    constexpr std::string_view pem_end = "-----END ";
    // Webhooks whose path is their credential: Slack's, Discord's and Microsoft Teams'.
    constexpr std::string_view slack_hooks = "hooks.slack.com/services/";
    constexpr std::string_view discord_hooks = "discord.com/api/webhooks/";
    constexpr std::string_view discordapp_hooks = "discordapp.com/api/webhooks/";
    constexpr std::string_view teams_hooks = "webhook.office.com/webhookb2/";
    constexpr std::size_t minimum_hook_path = 10;

    // text.substr(offset, count) that cannot throw: an offset past the end gives an empty view.
    constexpr std::string_view slice(std::string_view text, std::size_t offset, std::size_t count = std::string_view::npos) noexcept {
      text.remove_prefix(std::min(offset, text.size()));
      text.remove_suffix(text.size() - std::min(count, text.size()));
      return text;
    }

    constexpr bool upper(unsigned char byte) noexcept {
      return byte >= 'A' && byte <= 'Z';
    }

    constexpr bool lower(unsigned char byte) noexcept {
      return byte >= 'a' && byte <= 'z';
    }

    constexpr bool digit(unsigned char byte) noexcept {
      return byte >= '0' && byte <= '9';
    }

    constexpr bool alphanumeric(unsigned char byte) noexcept {
      return upper(byte) || lower(byte) || digit(byte);
    }

    constexpr unsigned char folded(unsigned char byte) noexcept {
      return upper(byte) ? static_cast<unsigned char>(byte + ('a' - 'A')) : byte;
    }

    constexpr bool holds(Alphabet alphabet, unsigned char byte) noexcept {
      switch (alphabet) {
      case Alphabet::upper:
        return upper(byte) || digit(byte);
      case Alphabet::upper_dashed:
        return upper(byte) || digit(byte) || byte == '-';
      case Alphabet::alphanumeric:
        return alphanumeric(byte);
      case Alphabet::word:
        return alphanumeric(byte) || byte == '_';
      case Alphabet::url:
        return alphanumeric(byte) || byte == '_' || byte == '-';
      case Alphabet::dashed:
        return alphanumeric(byte) || byte == '-';
      case Alphabet::dotted:
        return alphanumeric(byte) || byte == '_' || byte == '-' || byte == '.';
      case Alphabet::base64:
        return alphanumeric(byte) || byte == '+' || byte == '/' || byte == '=' || byte == '_' || byte == '-';
      case Alphabet::hex:
        return digit(byte) || (byte >= 'a' && byte <= 'f');
      }

      return false;
    }

    // A byte a key or a name may hold, which a marker must not follow.
    constexpr bool nameByte(unsigned char byte) noexcept {
      return alphanumeric(byte) || byte == '_' || byte == '-';
    }

    std::size_t run(std::string_view text, std::size_t from, Alphabet alphabet) noexcept {
      auto end = from;

      while (end < text.size() && holds(alphabet, static_cast<unsigned char>(text[end]))) {
        ++end;
      }

      return end;
    }

    ds::Option<SecretSpan> token(std::string_view text, std::size_t start) noexcept {
      if (start != 0 && nameByte(static_cast<unsigned char>(text[start - 1]))) {
        return ds::none;
      }

      const auto rest = slice(text, start);
      const auto range = rules_by_byte[static_cast<unsigned char>(text[start])];

      for (const auto& rule : token_rules.view().subspan(range.begin, range.end - range.begin)) {
        if (!rest.starts_with(rule.marker)) {
          continue;
        }

        const auto end = run(text, start + rule.marker.size(), rule.alphabet);
        if (end - start - rule.marker.size() >= rule.minimum) {
          return SecretSpan{.begin = start, .end = end, .kind = SecretKind::token};
        }

        // A longer marker that did not hold a key leaves the shorter ones after it to try.
      }

      return ds::none;
    }

    bool secretName(std::string_view name) noexcept {
      while (!name.empty() && (name.front() == '-' || name.front() == '"' || name.front() == '\'')) {
        name.remove_prefix(1);
      }

      const auto ends_with = [name](std::string_view suffix) noexcept {
        if (name.size() < suffix.size()) {
          return false;
        }

        const auto tail = slice(name, name.size() - suffix.size());

        return std::ranges::equal(tail, suffix, [](char left, char right) noexcept {
          return folded(static_cast<unsigned char>(left)) == static_cast<unsigned char>(right);
        });
      };

      if (std::ranges::any_of(secret_names, ends_with)) {
        return true;
      }

      // Azure's keys are named by the service they open: AZURE_STORAGE_KEY, AZURE_OPENAI_KEY.
      constexpr std::string_view azure = "azure_";

      return name.size() > std::string_view{"azure_key"}.size() && ends_with("key") && std::ranges::equal(slice(name, 0, azure.size()), azure, [](char left, char right) noexcept {
        return folded(static_cast<unsigned char>(left)) == static_cast<unsigned char>(right);
      });
    }

    // The name that ends right before `end`, at most maximum_name_bytes long.
    std::string_view nameBefore(std::string_view text, std::size_t end) noexcept {
      auto begin = end;

      while (begin != 0 && end - begin < maximum_name_bytes && nameByte(static_cast<unsigned char>(text[begin - 1]))) {
        --begin;
      }

      return slice(text, begin, end - begin);
    }

    // The value that starts at `start`: quoted, up to its closing quote, or bare, up to a blank or
    // a shell separator. A reference to a variable names no secret.
    ds::Option<SecretSpan> value(std::string_view text, std::size_t start) noexcept {
      if (start >= text.size()) {
        return ds::none;
      }

      const auto quote = text[start];
      const bool quoted = quote == '"' || quote == '\'';
      const auto begin = quoted ? start + 1 : start;

      // Told before the value is read, so a run of references is read once, not once each.
      if (begin == text.size() || text[begin] == '$') {
        return ds::none;
      }

      auto end = begin;

      if (quoted) {
        while (end < text.size() && text[end] != quote && text[end] != '\n') {
          end += text[end] == '\\' && quote == '"' && end + 1 < text.size() ? 2 : 1;
        }

        end = std::min(end, text.size());
      } else {
        while (end < text.size() && !std::string_view{" \t\r\n;&|)`"}.contains(text[end])) {
          ++end;
        }
      }

      if (end == begin) {
        return ds::none;
      }

      return SecretSpan{.begin = begin, .end = end, .kind = SecretKind::structural};
    }

    // `NAME=value`, `--password=value`, `export DB_PASSWORD="value"`.
    ds::Option<SecretSpan> assignment(std::string_view text, std::size_t equals) noexcept {
      const auto name = nameBefore(text, equals);
      if (name.empty() || !secretName(name)) {
        return ds::none;
      }

      return value(text, equals + 1);
    }

    // `"client_secret": "value"`, as JSON and the configuration files that print like it write it.
    ds::Option<SecretSpan> member(std::string_view text, std::size_t colon) noexcept {
      auto close = colon;

      while (close != 0 && text[close - 1] == ' ') {
        --close;
      }

      if (close < 2 || text[close - 1] != '"') {
        return ds::none;
      }

      const auto name = nameBefore(text, close - 1);
      if (name.empty() || name.size() >= close - 1 || text[close - 2 - name.size()] != '"' || !secretName(name)) {
        return ds::none;
      }

      auto start = colon + 1;

      while (start < text.size() && text[start] == ' ') {
        ++start;
      }

      if (start >= text.size() || text[start] != '"') {
        return ds::none;
      }

      return value(text, start);
    }

    // The password of `scheme://user:password@host`.
    ds::Option<SecretSpan> urlPassword(std::string_view text, std::size_t colon) noexcept {
      if (!slice(text, colon).starts_with("://") || colon == 0 || !alphanumeric(static_cast<unsigned char>(text[colon - 1]))) {
        return ds::none;
      }

      const auto authority = colon + 3;
      auto end = authority;
      ds::Option<std::size_t> separator;

      while (end < text.size() && !std::string_view{"/?#@ \t\r\n\"'"}.contains(text[end])) {
        if (text[end] == ':' && !separator) {
          separator = end;
        }

        ++end;
      }

      if (end == text.size() || text[end] != '@' || !separator || *separator + 1 == end) {
        return ds::none;
      }

      return SecretSpan{.begin = *separator + 1, .end = end, .kind = SecretKind::structural};
    }

    // The body of a private key's PEM block, between its two lines, or to the text's end when it
    // has no last line.
    ds::Option<SecretSpan> privateKey(std::string_view text, std::size_t start) noexcept {
      const auto rest = slice(text, start);
      if (!rest.starts_with(pem_begin)) {
        return ds::none;
      }

      const auto label_end = rest.find(pem_dashes, pem_begin.size());
      if (label_end == std::string_view::npos || !slice(rest, pem_begin.size(), label_end - pem_begin.size()).contains("PRIVATE KEY")) {
        return ds::none;
      }

      const auto begin = start + label_end + pem_dashes.size();
      const auto footer = text.find(pem_end, begin);

      return SecretSpan{.begin = begin, .end = footer == std::string_view::npos ? text.size() : footer, .kind = SecretKind::structural};
    }

    // The path of a webhook that starts at `start` with `hooks`, which is its credential.
    ds::Option<SecretSpan> hook(std::string_view text, std::size_t start, std::string_view hooks) noexcept {
      if (!slice(text, start).starts_with(hooks)) {
        return ds::none;
      }

      const auto begin = start + hooks.size();
      auto end = begin;

      while (end < text.size() && (nameByte(static_cast<unsigned char>(text[end])) || text[end] == '/' || text[end] == '@')) {
        ++end;
      }

      if (end - begin < minimum_hook_path) {
        return ds::none;
      }

      return SecretSpan{.begin = begin, .end = end, .kind = SecretKind::structural};
    }

    // A Telegram bot's token, 8 to 10 digits, a colon and 35 bytes, alone or where its API's URLs
    // put it, after `/bot`.
    ds::Option<SecretSpan> telegramBot(std::string_view text, std::size_t colon) noexcept {
      constexpr std::size_t fewest_digits = 8;
      constexpr std::size_t most_digits = 10;
      constexpr std::size_t secret_bytes = 35;
      auto begin = colon;

      while (begin != 0 && colon - begin <= most_digits && digit(static_cast<unsigned char>(text[begin - 1]))) {
        --begin;
      }

      const auto digits = colon - begin;
      if (digits < fewest_digits || digits > most_digits) {
        return ds::none;
      }

      if (begin != 0 && nameByte(static_cast<unsigned char>(text[begin - 1])) && !slice(text, 0, begin).ends_with("/bot")) {
        return ds::none;
      }

      const auto end = run(text, colon + 1, Alphabet::url);
      if (end - colon - 1 < secret_bytes) {
        return ds::none;
      }

      return SecretSpan{.begin = begin, .end = end, .kind = SecretKind::token};
    }

    // A Terraform Cloud token: 14 bytes, `.atlasv1.` and at least 60 more.
    ds::Option<SecretSpan> terraformToken(std::string_view text, std::size_t dot) noexcept {
      constexpr std::string_view marker = ".atlasv1.";
      constexpr std::size_t head_bytes = 14;
      constexpr std::size_t minimum = 60;

      if (dot < head_bytes || !slice(text, dot).starts_with(marker)) {
        return ds::none;
      }

      const auto begin = dot - head_bytes;
      const auto head = slice(text, begin, head_bytes);

      if (!std::ranges::all_of(head, [](char byte) noexcept {
            return lower(static_cast<unsigned char>(byte)) || digit(static_cast<unsigned char>(byte));
          }) ||
          (begin != 0 && nameByte(static_cast<unsigned char>(text[begin - 1])))) {
        return ds::none;
      }

      const auto end = run(text, dot + marker.size(), Alphabet::url);
      if (end - dot - marker.size() < minimum) {
        return ds::none;
      }

      return SecretSpan{.begin = begin, .end = end, .kind = SecretKind::token};
    }

    constexpr bool azureByte(unsigned char byte) noexcept {
      return alphanumeric(byte) || byte == '_' || byte == '~' || byte == '.';
    }

    // An Azure AD client secret: three bytes, a digit, `Q~` and 31 to 34 more.
    ds::Option<SecretSpan> azureSecret(std::string_view text, std::size_t tilde) noexcept {
      constexpr std::size_t head_bytes = 5;
      constexpr std::size_t fewest = 31;
      constexpr std::size_t most = 34;

      if (tilde < head_bytes || text[tilde - 1] != 'Q' || !digit(static_cast<unsigned char>(text[tilde - 2]))) {
        return ds::none;
      }

      const auto begin = tilde - head_bytes;
      const auto head = slice(text, begin, head_bytes - 2);

      if (!std::ranges::all_of(head, [](char byte) noexcept {
            return azureByte(static_cast<unsigned char>(byte));
          }) ||
          (begin != 0 && (azureByte(static_cast<unsigned char>(text[begin - 1])) || text[begin - 1] == '-'))) {
        return ds::none;
      }

      auto end = tilde + 1;

      // One byte past the most tells a longer run, which is no such secret, without reading it all.
      while (end < text.size() && end - tilde - 1 <= most && (azureByte(static_cast<unsigned char>(text[end])) || text[end] == '-')) {
        ++end;
      }

      const auto length = end - tilde - 1;
      if (length < fewest || length > most) {
        return ds::none;
      }

      return SecretSpan{.begin = begin, .end = end, .kind = SecretKind::token};
    }

    // The secret a rule that can start at `start` finds there; most bytes start none.
    ds::Option<SecretSpan> secretAt(std::string_view text, std::size_t start) noexcept {
      switch (text[start]) {
      case 'h':
        if (auto found = hook(text, start, slack_hooks)) {
          return found;
        }

        return token(text, start);
      case 'd':
        if (auto found = hook(text, start, discord_hooks)) {
          return found;
        }

        if (auto found = hook(text, start, discordapp_hooks)) {
          return found;
        }

        return token(text, start);
      case 'w':
        if (auto found = hook(text, start, teams_hooks)) {
          return found;
        }

        return token(text, start);
      case '-':
        return privateKey(text, start);
      case '=':
        return assignment(text, start);
      case ':':
        if (auto password = urlPassword(text, start)) {
          return password;
        }

        if (auto member_value = member(text, start)) {
          return member_value;
        }

        return telegramBot(text, start);
      case '.':
        return terraformToken(text, start);
      case '~':
        return azureSecret(text, start);
      default: {
        const auto range = rules_by_byte[static_cast<unsigned char>(text[start])];

        return range.begin == range.end ? ds::none : token(text, start);
      }
      }
    }

  }

  ds::Option<SecretSpan> findSecret(std::string_view text, std::size_t from) noexcept {
    for (auto start = from; start < text.size(); ++start) {
      // A rule that looks back from where it starts may find a secret begun before `from`, in
      // what the caller already read.
      if (auto found = secretAt(text, start); found && found->begin >= from) {
        return found;
      }
    }

    return ds::none;
  }

  ds::Option<SecretRedaction> redactSecrets(std::string_view text, std::span<char> out) noexcept {
    SecretRedaction result;
    std::size_t copied = 0;

    const auto write = [&](std::string_view piece) noexcept {
      if (piece.size() > out.size() - result.bytes) {
        return false;
      }

      std::ranges::copy(piece, out.begin() + static_cast<std::ptrdiff_t>(result.bytes));
      result.bytes += piece.size();
      return true;
    };

    for (auto found = findSecret(text); found; found = findSecret(text, found->end)) {
      if (!write(slice(text, copied, found->begin - copied)) || !write(secret_redaction)) {
        return ds::none;
      }

      ++result.secrets;
      if (found->kind == SecretKind::token) {
        result.token_bytes += found->end - found->begin;
      }

      copied = found->end;
    }

    if (!write(slice(text, copied))) {
      return ds::none;
    }

    return result;
  }

}
