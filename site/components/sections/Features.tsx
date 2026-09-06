import Digest from "@/components/diagrams/Digest";
import Lanes from "@/components/diagrams/Lanes";
import Modes from "@/components/diagrams/Modes";
import Pipeline from "@/components/diagrams/Pipeline";
import Split from "@/components/diagrams/Split";
import Wire from "@/components/diagrams/Wire";
import HistoryList from "@/components/HistoryList";
import Reveal from "@/components/Reveal";
import Feature from "./Feature";

export default function Features() {
  return (
    <section id="why" className="rails hairline">
      <Reveal className="px-5 pt-16 pb-6 md:px-8 md:pt-24">
        <p className="eyebrow" style={{ ["--i" as string]: 0 }}>
          why telar
        </p>
        <h2 className="title mt-5 max-w-[24ch] text-[clamp(1.9rem,3.6vw,3rem)]" style={{ ["--i" as string]: 1 }}>
          A multiplexer keeps the process alive. <em>telar keeps the agent.</em>
        </h2>
        <p className="measure mt-5 text-[16px] text-subtext" style={{ ["--i" as string]: 2 }}>
          tmux survives your laptop lid and knows nothing about what is running inside it. Supervisors know what an
          agent is doing as long as the agent tells them. telar sits where the bytes already pass, and owns it.
        </p>
      </Reveal>

      <ol className="mt-8">
        <Feature
          number="01"
          title={
            <>
              Owns the runtime. <em>Not a wrapper around it.</em>
            </>
          }
          figure={<Pipeline />}
        >
          <p>
            The agent&apos;s process is telar&apos;s child. Its pty is telar&apos;s pty. Its screen is a terminal emulator
            telar owns, one per pane, so telar never parses an escape sequence from a child and never guesses what the
            screen looks like.
          </p>
          <p>
            That is what makes the rest possible. You cannot search history you did not see, or know an agent is stuck
            from a hook it never fired.
          </p>
        </Feature>

        <Feature
          number="02"
          flip
          title={
            <>
              Reads the wire, <em>not the hooks.</em>
            </>
          }
          figure={<Wire />}
        >
          <p>
            Every pane gets a random 128-bit credential bound to that pane and its generation. A loopback proxy accepts
            only live credentials, intercepts only an allowlist of model APIs, and passes every other host through byte
            for byte. HTTP/1.1 and HTTP/2, with the origin validated before the child ever sees a certificate.
          </p>
          <p>
            From the exchanges telar derives <span className="text-peach">working</span>,{" "}
            <span className="text-peach">needs input</span> and <span className="text-mint">ready</span>. The state in
            the sidebar is what the agent did, not what it said it would do. Enabling the proxy never touches your OS
            trust store.
          </p>
        </Feature>

        <Feature
          number="03"
          title={
            <>
              Three paths, <em>three budgets.</em>
            </>
          }
          figure={<Lanes />}
        >
          <p>
            telar sits between your terminal and the pty, and between the agent and the network. Doing a lot of work
            there is acceptable only if you never feel it.
          </p>
          <p>
            So each path has its own budget and never waits on another. Parsing JSON or decoding an image while
            forwarding a keystroke crosses a budget. The work moves to its own queue and the keystroke goes.
          </p>
        </Feature>

        <Feature
          number="04"
          flip
          title={
            <>
              History that remembers <em>where.</em>
            </>
          }
          figure={
            <div className="space-y-3">
              <HistoryList />
              <p className="font-mono text-[11.5px] text-overlay-1">
                Press <kbd>Tab</kbd> in the box to narrow the scope. Commands typed by agents are kept apart from yours.
              </p>
            </div>
          }
        >
          <p>
            Every command lands in a local SQLite database with the workspace, directory and pane it ran in. The
            palette narrows from everything to this pane in three keystrokes.
          </p>
          <p>
            Agent conversations are indexed, not copied. Readers tail each agent&apos;s own session files by offset and
            store a preview and a byte range; one machine we measured holds 6.6 GB of Codex rollouts alone, and copying
            them into telar would have been the wrong kind of memory.
          </p>
        </Feature>

        <Feature
          number="05"
          title={
            <>
              Two processes. <em>One of them survives you.</em>
            </>
          }
          figure={<Split />}
        >
          <p>
            The runtime owns everything that has to outlive the screen. The client owns only what makes sense while
            somebody is looking, and all of it is disposable. The test for where a piece of state belongs is short: kill
            the client. If the session is ruined, it was in the wrong process.
          </p>
          <p>
            The client does not have to be on the same machine. <code className="font-mono text-[14px] text-text">telar --remote dev@box</code>{" "}
            forwards the runtime&apos;s Unix socket over SSH; the runtime cannot tell a forwarded client from a local one,
            and no TCP listener is ever exposed.
          </p>
        </Feature>

        <Feature
          number="06"
          flip
          title={
            <>
              Lua to the keys. <em>Plugins by digest.</em>
            </>
          }
          figure={<Digest />}
        >
          <p>
            One Lua file holds keybindings, profiles, themes and runtime settings, and reloads atomically: a typo never
            leaves you with half a config.
          </p>
          <p>
            A plugin is a content-addressed package. Its SHA-256 covers every path and every byte, and a trust grant
            binds the id, that exact digest and the capabilities you chose. Change a byte, lose the grant. Plugin code
            runs in isolated one-shot workers, never in the runtime or the client.
          </p>
        </Feature>

        <Feature
          number="07"
          tag="in design"
          title={
            <>
              Agent mode. <em>Same runtime, second view.</em>
            </>
          }
          figure={<Modes />}
        >
          <p>
            Supervising many agents wants a view by project and attention, not by tab and pane. The obvious build is a
            second runtime model of threads. telar will not do that: agent mode is another composition of the same client
            over the same runtime, and flipping it costs nothing.
          </p>
          <p>
            Accepted in ADR 0009 and 0010, not shipped yet. The decision is on the page so you can hold us to it.
          </p>
        </Feature>
      </ol>
    </section>
  );
}
