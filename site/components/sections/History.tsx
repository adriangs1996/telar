import HistoryList from "@/components/HistoryList";
import Story from "./Story";

export default function History() {
  return (
    <Story
      title="History you can actually search."
      intro={
        <>
          <p>
            Every command you run lands in a local SQLite database with the workspace, directory and pane it ran in.
            The palette narrows from everything to this pane in three keystrokes.
          </p>
          <p>
            Commands submitted by agents are kept apart, and shown only when you ask for them. Press{" "}
            <kbd className="rounded-sm border border-line px-1 font-mono text-[13px] text-text">/</kbd> anywhere on
            this page to open it.
          </p>
        </>
      }
    >
      <HistoryList />
    </Story>
  );
}
