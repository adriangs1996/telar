"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import { AGENT_SCRIPT, INITIAL_AGENTS, type Agent, type ToastKind } from "@/lib/agents";
import { PANES, paneById, paneByNumber, paneIndex, panesOfTab, type PaneId } from "@/lib/panes";
import type { ThemeName } from "@/lib/themes";

export type Direction = "up" | "down" | "left" | "right";

export type Overlay = "palette" | "keys" | null;

export type Mode = "normal" | "fullscreen" | "palette" | "keys";

export type Toast = { id: number; kind: ToastKind; title: string; body: string };

type Runtime = { pid: number; bytes: number; turns: number };

type ClientState = {
  focused: PaneId;
  fullscreen: boolean;
  overlay: Overlay;
  mode: Mode;
  attached: boolean;
  epoch: number;
  theme: ThemeName;
  agents: Agent[];
  toasts: Toast[];
  runtime: Runtime;
  focusPane: (id: PaneId, scroll?: boolean) => void;
  navigate: (direction: Direction) => void;
  toggleFullscreen: () => void;
  openOverlay: (overlay: Overlay) => void;
  closeOverlay: () => void;
  setTheme: (theme: ThemeName) => void;
  detach: () => void;
  attach: () => void;
  registerTrack: (element: HTMLElement | null) => void;
};

const ClientContext = createContext<ClientState | null>(null);

export function useClient(): ClientState {
  const value = useContext(ClientContext);
  if (!value) {
    throw new Error("useClient outside ClientProvider");
  }

  return value;
}

function prefersReducedMotion(): boolean {
  return typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

function isTyping(target: EventTarget | null): boolean {
  return target instanceof HTMLElement && target.matches("input, textarea, select, [contenteditable]");
}

// The page scrolls through one step per pane; the terminal window stays put
// and shows whichever pane the scroll position names.
export default function ClientProvider({ children }: { children: React.ReactNode }) {
  const [focused, setFocused] = useState<PaneId>("hero");
  const [fullscreen, setFullscreen] = useState(false);
  const [overlay, setOverlay] = useState<Overlay>(null);
  const [attached, setAttached] = useState(true);
  const [epoch, setEpoch] = useState(0);
  const [theme, setThemeState] = useState<ThemeName>("vesper");
  const [agents, setAgents] = useState<Agent[]>(INITIAL_AGENTS);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [runtime, setRuntime] = useState<Runtime>({ pid: 4812, bytes: 184_320, turns: 12 });

  const track = useRef<HTMLElement | null>(null);
  const programmaticUntil = useRef(0);
  const toastSeq = useRef(0);

  const registerTrack = useCallback((element: HTMLElement | null) => {
    track.current = element;
  }, []);

  const stepHeight = useCallback(() => {
    const element = track.current;
    return element ? element.offsetHeight / PANES.length : window.innerHeight;
  }, []);

  const scrollToPane = useCallback(
    (id: PaneId, behavior: ScrollBehavior) => {
      programmaticUntil.current = performance.now() + 1000;
      window.scrollTo({ top: paneIndex(id) * stepHeight(), behavior });
    },
    [stepHeight]
  );

  const focusPane = useCallback(
    (id: PaneId, scroll = true) => {
      setFocused((current) => {
        if (scroll) {
          const distance = Math.abs(paneIndex(id) - paneIndex(current));
          scrollToPane(id, prefersReducedMotion() || distance > 1 ? "auto" : "smooth");
        }
        return id;
      });
    },
    [scrollToPane]
  );

  // Up and down walk every pane in order. Left and right stay inside the tab,
  // the way panes sit beside each other in a split.
  const navigate = useCallback(
    (direction: Direction) => {
      const current = paneById(focused);
      if (direction === "down" || direction === "up") {
        const next = PANES[paneIndex(focused) + (direction === "down" ? 1 : -1)];
        if (next) {
          focusPane(next.id);
        }
        return;
      }

      const siblings = panesOfTab(current.tab);
      const at = siblings.findIndex((pane) => pane.id === focused);
      const next = siblings[at + (direction === "right" ? 1 : -1)];
      if (next) {
        focusPane(next.id);
      }
    },
    [focused, focusPane]
  );

  const toggleFullscreen = useCallback(() => setFullscreen((value) => !value), []);
  const openOverlay = useCallback((next: Overlay) => setOverlay(next), []);
  const closeOverlay = useCallback(() => setOverlay(null), []);
  const setTheme = useCallback((next: ThemeName) => setThemeState(next), []);

  const detach = useCallback(() => {
    setFullscreen(false);
    setOverlay(null);
    setToasts([]);
    setAttached(false);
  }, []);

  const attach = useCallback(() => {
    programmaticUntil.current = performance.now() + 1000;
    setAgents(INITIAL_AGENTS);
    setEpoch((value) => value + 1);
    setAttached(true);
  }, []);

  const pushToast = useCallback((kind: ToastKind, title: string, body: string) => {
    const id = ++toastSeq.current;
    setToasts((current) => [...current.slice(-2), { id, kind, title, body }]);
    window.setTimeout(() => setToasts((current) => current.filter((toast) => toast.id !== id)), 5200);
  }, []);

  // Theme reaches the chrome through one attribute; pane content keeps Vesper.
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
  }, [theme]);

  // Scroll position names the focused pane.
  useEffect(() => {
    let frame = 0;

    const probe = () => {
      frame = 0;
      if (!attached || performance.now() < programmaticUntil.current) {
        return;
      }

      const index = Math.max(0, Math.min(PANES.length - 1, Math.round(window.scrollY / stepHeight())));
      const id = PANES[index].id;
      setFocused((current) => (current === id ? current : id));
    };

    const onScroll = () => {
      if (!frame) {
        frame = requestAnimationFrame(probe);
      }
    };

    window.addEventListener("scroll", onScroll, { passive: true });
    probe();

    return () => {
      window.removeEventListener("scroll", onScroll);
      cancelAnimationFrame(frame);
    };
  }, [attached, epoch, stepHeight]);

  // A reconnecting client is placed back on the pane the runtime remembered.
  useEffect(() => {
    if (epoch > 0) {
      scrollToPane(focused, "auto");
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [epoch]);

  useEffect(() => {
    document.body.style.overflow = attached ? "" : "hidden";
    return () => {
      document.body.style.overflow = "";
    };
  }, [attached]);

  // Keyboard, exactly as the bottom bar advertises it.
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.metaKey || event.ctrlKey || event.altKey || !attached) {
        return;
      }

      if (overlay) {
        if (event.key === "Escape" || (overlay === "keys" && event.key === "?")) {
          event.preventDefault();
          setOverlay(null);
        }
        return;
      }

      if (isTyping(event.target)) {
        return;
      }

      const number = parseInt(event.key, 10);
      if (number >= 1 && number <= PANES.length) {
        const pane = paneByNumber(number);
        if (pane) {
          event.preventDefault();
          focusPane(pane.id);
        }
        return;
      }

      switch (event.key) {
        case "j":
        case "ArrowDown":
          event.preventDefault();
          navigate("down");
          break;
        case "k":
        case "ArrowUp":
          event.preventDefault();
          navigate("up");
          break;
        case "h":
        case "ArrowLeft":
          event.preventDefault();
          navigate("left");
          break;
        case "l":
        case "ArrowRight":
          event.preventDefault();
          navigate("right");
          break;
        case "z":
        case "Enter":
          event.preventDefault();
          toggleFullscreen();
          break;
        case "Escape":
          setFullscreen(false);
          break;
        case "/":
          event.preventDefault();
          setOverlay("palette");
          break;
        case "?":
          event.preventDefault();
          setOverlay("keys");
          break;
      }
    };

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [attached, overlay, focusPane, navigate, toggleFullscreen]);

  // The runtime keeps counting whether or not a client is attached.
  useEffect(() => {
    const tick = window.setInterval(() => {
      setRuntime((current) => ({
        ...current,
        bytes: current.bytes + 512 + Math.floor(Math.random() * 3072),
        turns: current.turns + (Math.random() < 0.12 ? 1 : 0),
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

  // Focusing the pane of a `done` agent acknowledges it.
  useEffect(() => {
    setAgents((current) =>
      current.some((agent) => agent.pane === focused && agent.status === "done")
        ? current.map((agent) =>
            agent.pane === focused && agent.status === "done" ? { ...agent, status: "ready", rang: false } : agent
          )
        : current
    );
  }, [focused, agents]);

  const mode: Mode = overlay ?? (fullscreen ? "fullscreen" : "normal");

  const value = useMemo<ClientState>(
    () => ({
      focused,
      fullscreen,
      overlay,
      mode,
      attached,
      epoch,
      theme,
      agents,
      toasts,
      runtime,
      focusPane,
      navigate,
      toggleFullscreen,
      openOverlay,
      closeOverlay,
      setTheme,
      detach,
      attach,
      registerTrack,
    }),
    [
      focused,
      fullscreen,
      overlay,
      mode,
      attached,
      epoch,
      theme,
      agents,
      toasts,
      runtime,
      focusPane,
      navigate,
      toggleFullscreen,
      openOverlay,
      closeOverlay,
      setTheme,
      detach,
      attach,
      registerTrack,
    ]
  );

  return <ClientContext.Provider value={value}>{children}</ClientContext.Provider>;
}
