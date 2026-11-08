import type { Metadata } from "next";
import Sidebar from "@/components/docs/Sidebar";
import Toc from "@/components/docs/Toc";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./docs.css";

export const metadata: Metadata = {
  title: { template: "%s - Telar Docs", default: "Telar Docs" },
  description: "Documentation for Telar: panes, tabs, workspaces, agents, remote machines, configuration and the TLS proxy.",
};

export default function DocsLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="docs">
      <SiteHeader docs />
      <div className="docs-body">
        <aside className="docs-rail">
          <Sidebar />
        </aside>
        <main className="docs-main">{children}</main>
        <aside className="docs-rail docs-rail-end">
          <Toc />
        </aside>
      </div>
      <SiteFooter />
    </div>
  );
}
