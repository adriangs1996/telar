import Nav from "@/components/Nav";
import DemoProvider from "@/components/demo/DemoProvider";
import Compare from "@/components/sections/Compare";
import Demo from "@/components/sections/Demo";
import Features from "@/components/sections/Features";
import Footer from "@/components/sections/Footer";
import Hero from "@/components/sections/Hero";
import Install from "@/components/sections/Install";
import Proof from "@/components/sections/Proof";

export default function Page() {
  return (
    <DemoProvider>
      <Nav />
      <main>
        <Hero />
        <Proof />
        <Demo />
        <Features />
        <Compare />
        <Install />
      </main>
      <Footer />
    </DemoProvider>
  );
}
