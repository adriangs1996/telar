"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import { AGENT_SCRIPT, INITIAL_AGENTS, type Agent, type ToastKind } from "@/lib/agents";
import { THEMES, type ThemeName } from "@/lib/themes";

const THEME_KEY = "telar.theme";

function storedTheme(): ThemeName | null {
  try {
    const value = window.localStorage.getItem(THEME_KEY);
    return THEMES.some((theme) => theme.id === value) ? (value as ThemeName) : null;
  } catch {
    return null;
  }
}

export type Toast = { id: number; kind: ToastKind; title: string; body: string };

type Runtime = { pid: number; bytes: number; turns: number; since: number };

type DemoState = {
  agents: Agent[];
  focused: string;
  attached: boolean;
  epoch: number;
  theme: ThemeName;
  toasts: Toast[];
  runtime: Runtime;
  focusAgent: (id: string) => void;
  focusTab: (tab: string) => void;
  step: (delta: number) => void;
  setTheme: (theme: ThemeName) => void;
  detach: () => void;
  attach: () => void;
};

const DemoContext = createContext<DemoState | null>(null);

export function useDemo(): DemoState {
  const value = useContext(DemoContext);
  if (!value) {
    throw new Error("useDemo outside DemoProvider");
  }

  return value;
}

// The runtime half of the demo. Agents change state on a script after every
// attach, the counters keep moving whether or not a client is drawn, and the
// only thing a detach throws away is the window.
export default function DemoProvider({ children }: { children: React.ReactNode }) {
  const [agents, setAgents] = useState<Agent[]>(INITIAL_AGENTS);
  const [focused, setFocused] = useState(INITIAL_AGENTS[0].id);
  const [attached, setAttached] = useState(true);
  const [epoch, setEpoch] = useState(0);
  const [theme, setThemeState] = useState<ThemeName>("vesper");
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [runtime, setRuntime] = useState<Runtime>({ pid: 4812, bytes: 184_320, turns: 12, since: 0 });
  const toastSeq = useRef(0);
  const themeChosen = useRef(false);

  const pushToast = useCallback((kind: ToastKind, title: string, body: string) => {
    const id = ++toastSeq.current;
    setToasts((current) => [...current.slice(-2), { id, kind, title, body }]);
    window.setTimeout(() => setToasts((current) => current.filter((toast) => toast.id !== id)), 5200);
  }, []);

  const focusAgent = useCallback((id: string) => setFocused(id), []);

  // A tab with no agent in it stays a tab: focus lands on its first agent
  // when there is one, and otherwise the sidebar keeps its selection.
  const focusTab = useCallback(
    (tab: string) => {
      const first = agents.find((agent) => agent.tab === tab);
      if (first) {
        setFocused(first.id);
      }
    },
    [agents]
  );

  const step = useCallback(
    (delta: number) => {
      const index = agents.findIndex((agent) => agent.id === focused);
      const next = agents[Math.max(0, Math.min(agents.length - 1, index + delta))];
      if (next) {
        setFocused(next.id);
      }
    },
    [agents, focused]
  );

  const setTheme = useCallback((next: ThemeName) => {
    themeChosen.current = true;
    setThemeState(next);
  }, []);

  const detach = useCallback(() => {
    setToasts([]);
    setAttached(false);
  }, []);

  const attach = useCallback(() => {
    setAgents(INITIAL_AGENTS);
    setEpoch((value) => value + 1);
    setAttached(true);
  }, []);

  // The theme reaches the whole page through one attribute on the root, and
  // survives a reload. Until the visitor picks one, a stored choice wins over
  // the default, and nothing is written until that choice has been adopted.
  useEffect(() => {
    const stored = storedTheme();
    if (stored && stored !== theme && !themeChosen.current) {
      setThemeState(stored);
      return;
    }

    document.documentElement.dataset.theme = theme;
    try {
      window.localStorage.setItem(THEME_KEY, theme);
    } catch {
      // Private mode or blocked storage: the theme still applies for this visit.
    }
  }, [theme]);

  // The runtime keeps counting whether or not a client is attached.
  useEffect(() => {
    const started = performance.now();
    const tick = window.setInterval(() => {
      setRuntime((current) => ({
        ...current,
        bytes: current.bytes + 512 + Math.floor(Math.random() * 3072),
        turns: current.turns + (Math.random() < 0.12 ? 1 : 0),
        since: Math.floor((performance.now() - started) / 1000),
      }));
    }, 900);

    return () => window.clearInterval(tick);
  }, []);

  // Agent activity after each attach.
  useEffect(() => {
    if (!attached) {
      return;
    }

    const timers = AGENT_SCRIPT.map((event) =>
      window.setTimeout(() => {
        setAgents((current) => current.map((agent) => (agent.id === event.id ? { ...agent, ...event.patch } : agent)));
        if (event.toast) {
          pushToast(event.toast.kind, event.toast.title, event.toast.body);
        }
        if (event.patch.status === "done") {
          setRuntime((current) => ({ ...current, turns: current.turns + 1 }));
        }
      }, event.at)
    );

    return () => timers.forEach((timer) => window.clearTimeout(timer));
  }, [attached, epoch, pushToast]);

  // Looking at a `done` agent acknowledges it.
  useEffect(() => {
    setAgents((current) =>
      current.some((agent) => agent.id === focused && agent.status === "done")
        ? current.map((agent) => (agent.id === focused && agent.status === "done" ? { ...agent, status: "ready", rang: false } : agent))
        : current
    );
  }, [focused, agents]);

  const value = useMemo<DemoState>(
    () => ({ agents, focused, attached, epoch, theme, toasts, runtime, focusAgent, focusTab, step, setTheme, detach, attach }),
    [agents, focused, attached, epoch, theme, toasts, runtime, focusAgent, focusTab, step, setTheme, detach, attach]
  );

  return <DemoContext.Provider value={value}>{children}</DemoContext.Provider>;
}
