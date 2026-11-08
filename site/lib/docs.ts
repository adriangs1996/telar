// The documentation's one table of contents: the sidebar, the breadcrumbs and
// the page titles all read it, so a page is added here once.
export type DocPage = { slug: string; title: string; lead: string };
export type DocSection = { title: string; pages: DocPage[] };

export const DOCS_ROOT: DocPage = {
  slug: "",
  title: "Telar Docs",
  lead: "Persistent terminals, agents and remote machines in one native window.",
};

export const DOC_SECTIONS: DocSection[] = [
  {
    title: "Terminal",
    pages: [
      { slug: "panes", title: "Panes", lead: "Split a tab into terminals, move between them and resize them." },
      { slug: "tabs", title: "Tabs", lead: "Group panes into tabs inside a workspace." },
      { slug: "workspaces", title: "Workspaces", lead: "Keep each project's tabs, directory and agents together." },
    ],
  },
  {
    title: "Agents",
    pages: [
      { slug: "agents", title: "Agents", lead: "Run coding agents in panes and follow their status from the sidebar." },
      { slug: "remote-machines", title: "Remote Machines", lead: "Connect the window to runtimes on other machines over SSH." },
    ],
  },
  {
    title: "Find",
    pages: [
      { slug: "command-palette", title: "Command Palette", lead: "Find an action, a workspace or a machine by name." },
      { slug: "history", title: "History", lead: "Search the commands your shells and agents ran." },
      { slug: "paths", title: "Paths", lead: "Find files and directories under the focused pane's directory and open the paths a terminal prints." },
    ],
  },
  {
    title: "Configuration",
    pages: [
      { slug: "config", title: "Config", lead: "Configure themes, fonts, keybindings and the sidebar in Lua." },
      { slug: "proxy", title: "Proxy", lead: "Route your panes' HTTPS traffic through Telar's TLS proxy to inspect it." },
    ],
  },
];

export const REPOSITORY = "https://github.com/adriangs1996/telar";

export function findDoc(slug: string): { section?: DocSection; page: DocPage } | undefined {
  if (slug === "") return { page: DOCS_ROOT };
  for (const section of DOC_SECTIONS) {
    const page = section.pages.find((candidate) => candidate.slug === slug);
    if (page) return { section, page };
  }
  return undefined;
}
