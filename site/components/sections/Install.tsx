import Story from "./Story";

const steps = [
  { cmd: "brew install sqlite libnghttp2", note: "The runtime links system SQLite and libnghttp2." },
  { cmd: "git clone https://github.com/adriangs1996/telar && cd telar", note: "" },
  { cmd: "zig build run", note: "Zig 0.16. Pass --theme or --sidebar-renderer after a double dash." },
];

export default function Install() {
  return (
    <Story
      wide
      title="Build it from source."
      intro={
        <>
          <p>Telar is written in Zig and runs on macOS and Linux. There is no binary release yet.</p>
          <p>
            It runs every day on the machine it is written on, and not on many others yet. Expect sharp edges, and
            expect them to be fixed in the open.
          </p>
        </>
      }
    >
      <ol className="space-y-5">
        {steps.map((step, index) => (
          <li key={step.cmd}>
            <pre className="overflow-x-auto rounded-md border border-line bg-panel px-5 py-3.5 font-mono text-[13.5px] text-text">
              <code>
                <span className="text-peach">$ </span>
                {step.cmd}
                {index === steps.length - 1 ? <span className="cursor" /> : null}
              </code>
            </pre>
            {step.note ? <p className="mt-2 text-[14px] text-overlay-1">{step.note}</p> : null}
          </li>
        ))}
      </ol>
    </Story>
  );
}
