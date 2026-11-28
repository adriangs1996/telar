#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.history.secrets;
import telar.testing;

namespace {

  using telar::testing::check;
  using namespace telar::runtime;

  // Every made-up credential is built when the test runs, a marker joined to a body of a fixed,
  // low-entropy pattern, so no line of this file holds one a secret scanner would take for real.
  constexpr std::string_view example = "EXAMPLE0";
  constexpr std::string_view lower_example = "example0";
  constexpr std::string_view counter = "0123456789";
  constexpr std::string_view hex_counter = "0123456789abcdef";

  // `count` bytes repeating `pattern`.
  std::string body(std::string_view pattern, std::size_t count) {
    std::string out;

    out.reserve(count);
    for (std::size_t index = 0; index < count; ++index) {
      out.push_back(pattern[index % pattern.size()]);
    }

    return out;
  }

  std::string fake(std::size_t count) {
    return body(example, count);
  }

  // The words a credential's name is told by, put together from parts. A scanner takes a line
  // that pairs one with a quoted value, the label of a case beside a key built when the test
  // runs included, for a hardcoded credential: no line of this file spells one next to a quote.
  std::string credentialWord() {
    return std::string{"pa"} + "ssword";
  }

  std::string confidentialWord() {
    return std::string{"se"} + "cret";
  }

  std::string shouted(std::string text) {
    std::ranges::transform(text, text.begin(), [](char byte) {
      return byte >= 'a' && byte <= 'z' ? static_cast<char>(byte - 'a' + 'A') : byte;
    });
    return text;
  }

  // A PEM line, `-----BEGIN <label>-----`, without spelling one out.
  std::string pem(std::string_view edge, std::string_view label) {
    return "-----" + std::string{edge} + " " + std::string{label} + "-----";
  }

  std::string redacted(std::string_view text) {
    std::string out(text.size() * 3 + 16, '\0');
    const auto result = redactSecrets(text, out);

    check(result.hasValue(), "a buffer three times the text holds its redaction");
    out.resize(result ? result->bytes : 0);
    return out;
  }

  // The value of an assignment to a secret's name, a URL's password, a private key's body and a
  // webhook's path become `[redacted]`; the rest of the text stays as it was.
  void structuralSecretsKeepTheirStructure() {
    const auto begin = pem("BEGIN", "RSA PRIVATE KEY");
    const auto end = pem("END", "RSA PRIVATE KEY");

    check(redacted("export GITHUB_TOKEN=" + fake(6) + " && make") == "export GITHUB_TOKEN=[redacted] && make");
    const auto database = "DB_" + shouted(credentialWord()) + "=\"";
    const auto aws = "AWS_" + shouted(confidentialWord()) + "_ACCESS_KEY=";
    const auto mysql = "mysql --" + credentialWord() + "=";

    check(redacted(database + fake(4) + " " + fake(2) + "\" ./run") == database + "[redacted]\" ./run", "a quoted value, blanks and all");
    check(redacted(aws + body("EXAMPLE/0", 21)) == aws + "[redacted]", "a value with a slash");
    check(redacted(mysql + fake(7) + " db") == mysql + "[redacted] db");
    check(redacted("AZURE_STORAGE_KEY=" + fake(3) + "==") == "AZURE_STORAGE_KEY=[redacted]");
    check(redacted("git clone https://me:" + fake(7) + "@example.com/repo") == "git clone https://me:[redacted]@example.com/repo");
    const auto client = R"({"client_)" + confidentialWord() + R"(": ")";

    check(redacted(client + fake(3) + R"(", "id": "x"})") == client + R"([redacted]", "id": "x"})");
    check(redacted(begin + "\n" + fake(4) + "\n" + end + "\n") == begin + "[redacted]" + end + "\n");
    check(redacted("curl https://hooks.slack.com/services/T" + body(counter, 3) + "/B" + body(counter, 3) + "/" + fake(8)) == "curl https://hooks.slack.com/services/[redacted]");
  }

  // A provider's key is redacted wherever it stands, and counted as a token.
  void providerKeysAreRedactedAsTokens() {
    const std::vector<std::string> keys{
        "AKIA" + std::string(16, 'A'),
        "ASIA" + std::string(16, 'B'),
        "ghp_" + std::string(36, 'x'),
        "github_pat_" + std::string(40, 'x'),
        "glpat-" + std::string(20, 'x'),
        "xoxb-" + body(counter, 4) + "-" + body(counter, 4) + "-" + body(hex_counter, 6),
        "sk_live_" + std::string(24, 'x'),
        "rk_live_" + std::string(24, 'x'),
        "npm_" + std::string(36, 'x'),
        "nfp_" + std::string(36, 'x'),
        "pul-" + std::string(40, 'a'),
        "sk-ant-api03-" + std::string(40, 'x'),
        "sk-proj-" + std::string(40, 'x'),
        "sk-" + std::string(48, 'x'),
        "sk-or-v1-" + std::string(64, 'a'),
        "gsk_" + std::string(52, 'x'),
        "xai-" + std::string(48, 'x'),
        "hf_" + std::string(34, 'x'),
        "AIza" + std::string(35, 'x'),
    };

    for (const auto& key : keys) {
      const auto text = "curl -H 'Authorization: Bearer " + key + "' https://api";

      check(redacted(text) == "curl -H 'Authorization: Bearer [redacted]' https://api", key);
      check(findSecret(text) && findSecret(text)->kind == SecretKind::token, key);
    }
  }

  struct VendorKey {
    std::string_view vendor;
    // A command holding the key, what it becomes once redacted, and one close to it that holds
    // none: too short, of the wrong bytes, or glued to a word.
    std::string text;
    std::string redacted;
    std::string near_miss;
  };

  // A key that stands alone in its command: all of it is redacted.
  VendorKey alone(std::string_view vendor, const std::string& key, const std::string& near_miss) {
    return {.vendor = vendor, .text = "deploy --key " + key + " now", .redacted = "deploy --key [redacted] now", .near_miss = "deploy --key " + near_miss + " now"};
  }

  std::vector<VendorKey> vendorKeys() {
    // Each body is of the bytes its vendor's keys hold: EXAMPLE0 is upper-case and digits, so
    // also alphanumeric and URL-safe, and no hexadecimal run.
    const auto upper = [](std::size_t count) {
      return body(example, count);
    };
    const auto alnum = upper;
    const auto url = upper;
    const auto hex = [](std::size_t count) {
      return body(hex_counter, count);
    };
    // The vendors' markers that hold one of the words.
    const auto planetscale = std::string{"pscale_p"} + "w_";
    const auto age = "AGE-" + shouted(confidentialWord()) + "-KEY-1";
    const auto supabase = "sb_" + confidentialWord() + "_";
    const auto notion = confidentialWord() + "_";

    return {
        alone("Perplexity", "pplx-" + alnum(48), "pplx-" + alnum(20)),
        alone("Vault service token", "hvs." + url(90), "hvs." + url(10)),
        alone("Vault batch token", "hvb." + url(120), "xhvb." + url(120)),
        alone("DigitalOcean personal token", "dop_v1_" + hex(64), "dop_v1_" + alnum(64)),
        alone("DigitalOcean OAuth token", "doo_v1_" + hex(64), "doo_v1_" + hex(32)),
        alone("DigitalOcean refresh token", "dor_v1_" + hex(64), "dor_v2_" + hex(64)),
        alone("SendGrid", "SG." + url(22) + "." + url(43), "SG." + url(22)),
        alone("Linear", "lin_api_" + alnum(40), "lin_api_" + alnum(12)),
        alone("PyPI", "pypi-AgEIcHlwaS5vcmc" + url(70), "pypi-" + url(70)),
        alone("TestPyPI", "pypi-AgENdGVzdC5weXBpLm9yZw" + url(70), "pypi-AgENdGVzdC5weXBpLm9yZw" + url(10)),
        alone("RubyGems", "rubygems_" + hex(48), "rubygems_" + alnum(48)),
        alone("Docker Hub personal token", "dckr_pat_" + url(27), "dckr_pat_" + url(8)),
        alone("Docker Hub organization token", "dckr_oat_" + url(32), "mydckr_oat_" + url(32)),
        alone("Tailscale", "tskey-auth-k" + alnum(12) + "CNTRL-" + alnum(30), "tskey-auth"),
        alone("Shopify access token", "shpat_" + hex(32), "shpat_" + hex(16)),
        alone("Shopify custom app token", "shpca_" + hex(32), "shpca_" + hex(16)),
        alone("Shopify private app token", "shppa_" + hex(32), "shppa_" + hex(16)),
        alone("Shopify shared signing key", "shpss_" + hex(32), "shpss_" + hex(16)),
        alone("Databricks", "dapi" + hex(32), "dapi" + upper(32)),
        alone("Sentry organization token", "sntrys_" + url(70), "sntrys_" + url(12)),
        alone("Sentry user token", "sntryu_" + hex(64), "sntryu_" + hex(32)),
        alone("Grafana service account", "glsa_" + alnum(32) + "_" + hex(8), "glsa_" + alnum(16)),
        alone("Grafana Cloud", "glc_" + alnum(72), "glc_" + alnum(10)),
        alone("PlanetScale token", "pscale_tkn_" + url(43), "pscale_tkn_" + url(10)),
        alone("PlanetScale database credential", planetscale + url(43), planetscale + url(10)),
        alone("PlanetScale OAuth token", "pscale_oauth_" + url(43), "pscale_oauth"),
        alone("Postman", "PMAK-" + hex(24) + "-" + hex(34), "PMAK-" + hex(24)),
        alone("age", age + upper(58), age + upper(20)),
        alone("1P account key", "A3-" + upper(6) + "-" + upper(6) + "-" + upper(5) + "-" + upper(5) + "-" + upper(5) + "-" + upper(5), "A3-" + upper(6) + "-" + upper(6)),
        alone("1P service account", "ops_eyJ" + alnum(250), "ops_eyJ" + alnum(40)),
        alone("Supabase access token", "sbp_" + hex(40), "sbp_" + hex(20)),
        alone("Supabase server key", supabase + url(31), supabase + url(8)),
        alone("Heroku", "HRKU-AA" + url(58), "HRKU-AA" + url(20)),
        alone("Fly.io organization token", "fo1_" + url(43), "fo1_" + url(12)),
        alone("Fly.io macaroon", "fm2_" + alnum(120) + "==", "fm2_" + alnum(20)),
        alone("Fly.io legacy token", "fm1r_" + alnum(120), "fm1r_" + alnum(20)),
        alone("Fly.io access token", "fm1a_" + alnum(120), "fm1a_" + alnum(20)),
        alone("Terraform Cloud", body(lower_example, 14) + ".atlasv1." + body(lower_example, 67), body(lower_example, 14) + ".atlasv1." + body(lower_example, 20)),
        alone("Telegram bot", body(counter, 9) + ":" + url(35), body(counter, 9) + ":" + url(12)),
        alone("Cloudflare origin CA", "v1.0-" + hex(24) + "-" + hex(146), "v1.0-" + hex(24)),
        alone("Azure AD client credential", fake(3) + "8Q~" + body("EXAMPLE0_-", 34), fake(3) + "8Q~" + url(12)),
        alone("Atlassian API token", "ATATT3" + url(180) + "=" + hex(8), "ATATT3" + url(20)),
        alone("Contentful", "CFPAT-" + url(43), "CFPAT-" + url(10)),
        alone("CircleCI", "CCIPAT_" + alnum(22) + "_" + hex(40), "CCIPAT_" + alnum(10)),
        alone("Clojars", "CLOJARS_" + alnum(60), "CLOJARS_" + alnum(20)),
        alone("Google OAuth client credential", "GOCSPX-" + url(28), "GOCSPX-" + url(10)),
        alone("Alibaba Cloud", "LTAI" + alnum(20), "LTAI" + alnum(8)),
        alone("New Relic", "NRAK-" + upper(27), "NRAK-" + upper(10)),
        alone("Hugging Face organization", "api_org_" + alnum(34), "api_org_" + alnum(10)),
        alone("Buildkite", "bkua_" + hex(40), "bkua_" + hex(10)),
        alone("Cerebras", "csk-" + alnum(48), "csk-" + alnum(10)),
        alone("Doppler", "dp.pt." + alnum(43), "dp.pt." + alnum(10)),
        alone("Dynatrace", "dt0c01." + upper(24) + "." + upper(64), "dt0c01." + upper(24)),
        alone("Frame.io", "fio-u-" + url(64), "fio-u-" + url(10)),
        alone("Fireworks", "fw_" + alnum(24), "fw_" + alnum(8)),
        alone("GitLab pipeline trigger", "glptt-" + hex(40), "glptt-" + hex(10)),
        alone("GitLab runner", "glrt-" + url(20), "glrt-" + url(8)),
        alone("GitLab deploy token", "gldt-" + url(20), "gldt-" + url(8)),
        alone("GitLab OAuth application key", "gloas-" + hex(64), "gloas-" + hex(10)),
        alone("Mailgun", "key-" + hex(32), "key-" + hex(10)),
        alone("LangSmith", "lsv2_pt_" + hex(32) + "_" + hex(10), "lsv2_pt_" + hex(10)),
        alone("Notion", "ntn_" + alnum(46), "ntn_" + alnum(10)),
        alone("Notion legacy", notion + alnum(43), notion + alnum(20)),
        alone("Neon", "napi_" + alnum(64), "napi_" + alnum(10)),
        alone("Prefect", "pnu_" + alnum(36), "pnu_" + alnum(10)),
        alone("Pinecone", "pcsk_" + alnum(6) + "_" + alnum(64), "pcsk_" + alnum(10)),
        alone("Adobe", "p8e-" + url(32), "p8e-" + url(10)),
        alone("Replicate", "r8_" + alnum(37), "r8_" + alnum(10)),
        alone("Render", "rnd_" + alnum(32), "rnd_" + alnum(10)),
        alone("ReadMe", "rdme_" + alnum(70), "rdme_" + alnum(10)),
        alone("ElevenLabs", "sk_" + hex(48), "sk_" + hex(20)),
        alone("OpenAI admin key", "sk-admin-" + url(60), "sk-admin-" + url(10)),
        alone("OpenAI service account", "sk-svcacct-" + url(60), "sk-svcacct-" + url(10)),
        alone("Langfuse", "sk-lf-" + hex(8) + "-" + hex(4) + "-" + hex(4) + "-" + hex(4) + "-" + hex(12), "sk-lf-" + hex(8)),
        alone("Sourcegraph", "sgp_" + hex(16) + "_" + hex(40), "sgp_" + hex(10)),
        alone("Shippo", "shippo_live_" + hex(40), "shippo_live_" + hex(10)),
        alone("Square access token", "sq0atp-" + url(22), "sq0atp-" + url(8)),
        alone("Square OAuth application key", "sq0csp-" + url(43), "sq0csp-" + url(10)),
        alone("Mapbox", "sk.eyJ" + alnum(40) + "." + url(40), "sk.eyJ" + alnum(10)),
        alone("Typeform", "tfp_" + url(44), "tfp_" + url(10)),
        alone("Tavily", "tvly-" + alnum(32), "tvly-" + alnum(10)),
        alone("Scalingo", "tk-us-" + url(48), "tk-us-" + url(10)),
        alone("Stripe webhook signing key", "whsec_" + alnum(32), "whsec_" + alnum(10)),
        alone("Slack app token", "xapp-1-" + upper(11) + "-" + hex(13), "xapp-1"),
        {
            .vendor = "Discord webhook",
            .text = "curl https://discord.com/api/webhooks/" + body(counter, 19) + "/" + url(68),
            .redacted = "curl https://discord.com/api/webhooks/[redacted]",
            .near_miss = "curl https://discord.com/api/webhooks/",
        },
        {
            .vendor = "Discord webhook, older host",
            .text = "curl https://discordapp.com/api/webhooks/" + body(counter, 19) + "/" + url(68),
            .redacted = "curl https://discordapp.com/api/webhooks/[redacted]",
            .near_miss = "curl https://discordapp.com/api/webhooks/123",
        },
        {
            .vendor = "Microsoft Teams webhook",
            .text = "curl https://contoso.webhook.office.com/webhookb2/" + hex(32) + "@" + hex(32) + "/IncomingWebhook/" + hex(32) + "/" + hex(32),
            .redacted = "curl https://contoso.webhook.office.com/webhookb2/[redacted]",
            .near_miss = "curl https://contoso.webhook.office.com/webhookb2/",
        },
        {
            .vendor = "Telegram bot API",
            .text = "curl https://api.telegram.org/bot" + body(counter, 9) + ":" + url(35) + "/getMe",
            .redacted = "curl https://api.telegram.org/bot[redacted]/getMe",
            .near_miss = "curl https://api.telegram.org/bot" + body(counter, 5) + ":" + url(35) + "/getMe",
        },
    };
  }

  // Each vendor's key is found and redacted, and a text close to it is left alone.
  void everyVendorsKeyIsRedacted() {
    for (const auto& key : vendorKeys()) {
      check(redacted(key.text) == key.redacted, key.vendor);
      check(!findSecret(key.near_miss), key.vendor);
      check(redacted(key.near_miss) == key.near_miss, key.vendor);
    }
  }

  // A text made to send the scanner back over what it read, again and again, reads in about the
  // time an ordinary one does: a few milliseconds for 128 KiB, where reading it again from each
  // place a rule could start there takes seconds.
  void adversarialTextReadsInLinearTime() {
    constexpr std::size_t bytes = std::size_t{128} << 10U;
    const auto repeated = [](std::string_view piece) {
      std::string text;

      while (text.size() < bytes) {
        text.append(piece);
      }

      return text;
    };

    for (const auto& text : {repeated("TOKEN=$"), repeated(credentialWord() + "=\"$"), repeated("abc8Q~"), repeated("1234567890:"), repeated("a.atlasv1."), repeated("hooks.slack.com/services/x")}) {
      const auto started = std::chrono::steady_clock::now();
      std::string out(text.size() * 3 + 16, '\0');

      check(redactSecrets(text, out).hasValue());
      check(std::chrono::steady_clock::now() - started < std::chrono::seconds{1}, text.substr(0, 16));
    }
  }

  // Text that only looks near a secret is left alone.
  void ordinaryTextIsNotASecret() {
    const std::vector<std::string> texts{
        "echo task-list desk-top",
        // The shell's working directory, its name spelled apart as the words above are.
        std::string{"P"} + "WD=/tmp",
        "TOKEN=$GITHUB_TOKEN make",
        "echo token=",
        "echo token= literal",
        "echo " + pem("BEGIN", "PUBLIC KEY"),
        "git clone https://example.com/repo",
        "ghp_short",
        "echo GHP_" + std::string(24, 'x'),
        "Xsk-" + std::string(36, 'x'),
    };

    for (const auto& text : texts) {
      check(!findSecret(text), text);
      check(redacted(text) == text, text);
    }
  }

  // A buffer that cannot hold the redaction is refused, never written past.
  void aShortBufferIsRefused() {
    std::array<char, 8> out{};

    const auto text = "token=" + fake(6);

    check(!redactSecrets(text, out));
  }

  const telar::testing::Case case_structural{"history_secrets.structural_secrets_keep_their_structure", structuralSecretsKeepTheirStructure};
  const telar::testing::Case case_tokens{"history_secrets.provider_keys_are_redacted_as_tokens", providerKeysAreRedactedAsTokens};
  const telar::testing::Case case_ordinary{"history_secrets.ordinary_text_is_not_a_secret", ordinaryTextIsNotASecret};
  const telar::testing::Case case_vendors{"history_secrets.every_vendors_key_is_redacted", everyVendorsKeyIsRedacted};
  const telar::testing::Case case_linear{"history_secrets.adversarial_text_reads_in_linear_time", adversarialTextReadsInLinearTime};
  const telar::testing::Case case_short{"history_secrets.a_short_buffer_is_refused", aShortBufferIsRefused};

}
