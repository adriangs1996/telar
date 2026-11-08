// The weaver: Telar's mascot hanging from its thread in a web that holds the
// terminals it runs. The lit terminal is the agent that needs you. An
// illustration, not live data; CSS animates it and reduced motion stills it.
const TERMINALS = [
  { title: "api · Codex", status: "Working · 4m", tone: "working", place: "left-[2%] top-[8%]" },
  { title: "zsh · ~/telar", status: "❯ just runtime-test", tone: "shell", place: "right-0 top-[12%]" },
  { title: "docs · Pi", status: "Done", tone: "done", place: "left-0 top-[66%]" },
  { title: "web · Claude Code", status: "Approval · Edit src/app.ts", tone: "lit", place: "right-[2%] top-[70%]" },
] as const;

export default function Weaver() {
  return (
    <div className="weaver" role="img" aria-label="Telar's mascot, a spider whose body is a terminal, holding four terminals in its web; one of them, an agent asking for approval, glows">
      <svg className="weaver-web" viewBox="0 0 520 430" preserveAspectRatio="xMidYMid meet" aria-hidden="true">
        <polygon points="260,40 430,120 470,260 360,390 160,390 50,260 90,120" />
        <polygon points="260,110 375,160 400,250 330,330 190,330 120,250 145,160" />
        <polygon points="260,170 320,195 335,245 300,285 220,285 185,245 200,195" />
        <path d="M260 215 L260 40 M260 215 L430 120 M260 215 L470 260 M260 215 L360 390 M260 215 L160 390 M260 215 L50 260 M260 215 L90 120" />
        <path className="weaver-thread" d="M260 0 V140" />
        <path className="weaver-thread" d="M300 250 L410 330" />
      </svg>
      <img className="weaver-mascot" src="/brand/telar-icon.svg" alt="" width={168} height={168} />
      {TERMINALS.map((terminal) => (
        <div key={terminal.title} className={`weaver-term absolute ${terminal.place}`} data-tone={terminal.tone} aria-hidden="true">
          <b>{terminal.title}</b>
          <span>
            {terminal.tone !== "shell" && <i />}
            {terminal.status}
          </span>
        </div>
      ))}
    </div>
  );
}
