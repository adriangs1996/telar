import Link from "next/link";
import CopyCommand from "@/components/CopyCommand";
import RuntimeDiagram from "@/components/landing/RuntimeDiagram";
import Weaver from "@/components/landing/Weaver";
import Reveal from "@/components/Reveal";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import { DOC_SECTIONS, REPOSITORY } from "@/lib/docs";
import "./landing.css";

const AGENTS = [
  { name: "Claude Code", logo: "/brand/providers/claude.png" },
  { name: "Codex", logo: "/brand/providers/codex.png" },
  { name: "Pi", logo: "/brand/providers/pi.svg" },
  { name: "Cursor Agent", logo: "/brand/providers/cursor.svg" },
  { name: "OpenCode", logo: "/brand/providers/opencode.svg" },
];

const CONFIG = `local telar = require("telar")

return telar.config({
  api_version = 2,
  theme = "cybervenom",
  gui = { font = { size = 16 } },
  client = {
    keybindings = {
      telar.bind({ "s" }, telar.action.toggle_sidebar()),
    },
  },
})`;

const BUILD = [
  "git clone https://github.com/adriangs1996/telar.git",
  "cd telar",
  "tools/cpp bootstrap",
  'export PATH="$PWD/.toolchain/bin:$PATH"',
  "just app",
];

export default function Landing() {
  return (
    <>
      <SiteHeader />
      <main>
        <section className="hero">
          <div>
            <p className="kicker">Terminal + multiplexer · macOS &amp; Linux</p>
            <h1 className="hero-title">
              One place to rule them all, and in the <em>web</em> bind them.
            </h1>
            <p className="hero-lead">
              Telar keeps your shells, editors and coding agents in workspaces, tabs and split panes. A runtime holds them
              all, so closing the window never stops the work, and the sidebar tells you which agent needs you.
            </p>
            <div className="flex flex-wrap gap-3">
              <Link href="/docs" className="button button-primary">
                Read the docs →
              </Link>
              <Link href="#get-started" className="button button-ghost">
                Build from source
              </Link>
            </div>
            <p className="hero-meta">Early development · MIT · C++23 and Qt Quick · terminal emulation by libghostty-vt</p>
          </div>
          <Weaver />
        </section>

        <Reveal as="section" className="band split">
          <div style={{ "--i": 0 } as React.CSSProperties}>
            <p className="kicker">The runtime</p>
            <h2 className="band-title">Close the window. The web holds.</h2>
            <p className="band-lead">
              The window is a view. A separate runtime owns every pane, its process and its history. Quit the window,
              reopen it later, and everything is where you left it. Point the window at a runtime on another machine over
              SSH, and its panes and agents stay there. <Link href="/docs/remote-machines">Remote machines →</Link>
            </p>
          </div>
          <div style={{ "--i": 1 } as React.CSSProperties}>
            <RuntimeDiagram />
          </div>
        </Reveal>

        <Reveal as="section" className="band">
          <div style={{ "--i": 0 } as React.CSSProperties}>
            <p className="kicker">The window</p>
            <h2 className="band-title">Every agent&apos;s status, beside your terminals.</h2>
            <p className="band-lead">
              Claude Code, Codex, Pi, Cursor Agent and OpenCode report their lifecycle to the sidebar. The one waiting for
              you stands out, and a click takes you to its pane. <Link href="/docs/agents">Agents →</Link>
            </p>
          </div>
          <figure className="screen" style={{ "--i": 1 } as React.CSSProperties}>
            <img src="/screens/window.png" alt="The Telar window in the Cybervenom theme: the agent sidebar, a coding agent and a shell in split panes" />
          </figure>
        </Reveal>

        <Reveal as="section" className="band">
          <div style={{ "--i": 0 } as React.CSSProperties}>
            <p className="kicker">Everything in the docs</p>
            <h2 className="band-title">A terminal you can reason about.</h2>
          </div>
          <div className="topics" style={{ "--i": 1 } as React.CSSProperties}>
            {DOC_SECTIONS.flatMap((section) =>
              section.pages.map((page) => (
                <Link key={page.slug} href={`/docs/${page.slug}`} className="topic">
                  <span className="topic-group">{section.title}</span>
                  <b>{page.title}</b>
                  <span className="topic-lead">{page.lead}</span>
                </Link>
              )),
            )}
          </div>
        </Reveal>

        <Reveal as="section" className="band split">
          <div style={{ "--i": 0 } as React.CSSProperties}>
            <p className="kicker">Agents</p>
            <h2 className="band-title">Bring the agents you already use.</h2>
            <p className="band-lead">
              An integration installs hooks in the agent&apos;s own configuration. Without one, Telar still recognizes the
              agent from its process and its screen.
            </p>
            <div className="agents">
              {AGENTS.map((agent) => (
                <span key={agent.name}>
                  <img src={agent.logo} alt="" width={22} height={22} />
                  {agent.name}
                </span>
              ))}
            </div>
          </div>
          <pre className="code" style={{ "--i": 1 } as React.CSSProperties}>
            <span className="comment"># one command per agent</span>
            {"\ntelar integration install claude\ntelar integration install codex\n\n"}
            <span className="comment"># then work as usual, inside a pane</span>
            {"\nclaude"}
          </pre>
        </Reveal>

        <Reveal as="section" className="band split">
          <div style={{ "--i": 0 } as React.CSSProperties}>
            <p className="kicker">Configuration</p>
            <h2 className="band-title">Configure it in Lua.</h2>
            <p className="band-lead">
              One file sets themes, fonts, keybindings, bars and the runtime. Telar reloads it when you save, and keeps the
              last good one when the new file has an error. <Link href="/docs/config">Config →</Link>
            </p>
          </div>
          <pre className="code" style={{ "--i": 1 } as React.CSSProperties}>
            {CONFIG}
          </pre>
        </Reveal>

        <Reveal as="section" className="band split">
          <div id="get-started" style={{ "--i": 0 } as React.CSSProperties}>
            <p className="kicker">Get started</p>
            <h2 className="band-title">Build it from source.</h2>
            <p className="band-lead">
              There is no release yet. The bootstrap installs a pinned LLVM, CMake, Ninja and Just inside the checkout,
              and the first configure builds libghostty-vt and Qt. The{" "}
              <a href={`${REPOSITORY}/blob/main/docs/build/cpp-modules.md`}>build guide</a> lists the platform
              requirements.
            </p>
          </div>
          <div className="flex flex-col gap-2" style={{ "--i": 1 } as React.CSSProperties}>
            {BUILD.map((command) => (
              <CopyCommand key={command} command={command} />
            ))}
          </div>
        </Reveal>
      </main>
      <SiteFooter />
    </>
  );
}
