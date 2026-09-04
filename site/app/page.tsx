import Chrome from "@/components/client/Chrome";
import ClientProvider from "@/components/client/ClientProvider";
import Screens from "@/components/client/Screens";
import Config from "@/components/sections/Config";
import Glossary from "@/components/sections/Glossary";
import Hero from "@/components/sections/Hero";
import History from "@/components/sections/History";
import Install from "@/components/sections/Install";
import Paths from "@/components/sections/Paths";
import Server from "@/components/sections/Server";
import SidebarStory from "@/components/sections/SidebarStory";

export default function Page() {
  return (
    <ClientProvider>
      <Chrome>
        <Screens
          panes={{
            hero: <Hero />,
            sidebar: <SidebarStory />,
            server: <Server />,
            paths: <Paths />,
            history: <History />,
            config: <Config />,
            install: <Install />,
            glossary: <Glossary />,
          }}
        />
      </Chrome>
    </ClientProvider>
  );
}
