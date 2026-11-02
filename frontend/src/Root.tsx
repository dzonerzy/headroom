import { useEffect, useState, type FormEvent } from "react";
// Generated from src/app.zig at every build: App's methods and events, typed.
import { App, Events, type Greeting } from "./bindings";
import { duration, steps } from "./format";

type Work = { state: "idle" } | { state: "running" } | { state: "finished"; took: string };

export default function Root() {
  const [name, setName] = useState("");
  const [greeting, setGreeting] = useState<(Greeting & { took: string }) | null>(null);
  const [done, setDone] = useState(0);
  const [work, setWork] = useState<Work>({ state: "idle" });

  // Zig's "progress" events; the returned function stops listening.
  useEffect(() => Events.on("progress", (progress) => setDone(progress.done)), []);

  function greet(event: FormEvent) {
    event.preventDefault();
    const start = performance.now();
    // Synchronous: Zig runs in this process, no await needed.
    const answer = App.greet(name);
    setGreeting({ ...answer, took: duration(performance.now() - start) });
  }

  async function count() {
    setDone(0);
    setWork({ state: "running" });
    const start = performance.now();
    try {
      await App.countTo(steps);
      setWork({ state: "finished", took: duration(performance.now() - start) });
    } catch {
      setWork({ state: "idle" });
    }
  }

  return (
    <main className="shell">
      <header className="masthead">
        <span className="mark" aria-hidden="true" />
        <div>
          <h1 className="title">Headroom</h1>
          <p className="lede">This window is React; the work behind it is Zig, in the same process.</p>
        </div>
      </header>

      <section className="greet">
        <form className="ask" onSubmit={greet}>
          <label htmlFor="name" className="sr-only">Your name</label>
          <input id="name" className="field" placeholder="Your name" autoComplete="off"
            value={name} onChange={(event) => setName(event.target.value)} />
          <button className="action">Greet</button>
        </form>
        {greeting ? (
          <p key={greeting.number} className="answer" data-written aria-live="polite">{greeting.text}</p>
        ) : (
          <p className="answer" data-empty>Say hello to Zig.</p>
        )}
        <p className="trace">
          {greeting && <>Answered by Zig in <span className="code">{greeting.took}</span> (greeting {greeting.number}).</>}
        </p>
      </section>

      <section className="work">
        <h2>Work on another thread</h2>
        <button className="action action-quiet" onClick={count} disabled={work.state === "running"}>
          {work.state === "finished" ? "Count again" : "Start"}
        </button>
        <div className="barbs" role="progressbar" aria-label="Progress" aria-valuemin={0} aria-valuemax={steps} aria-valuenow={done}>
          {Array.from({ length: steps }, (_, i) => (
            <span key={i} className="barb" data-on={i < done ? "" : undefined} />
          ))}
        </div>
        <p className="trace">
          {work.state === "idle" && `Start, and Zig counts to ${steps} on a worker thread, sending an event at each step.`}
          {work.state === "running" && `Counted ${done} of ${steps}.`}
          {work.state === "finished" && `Counted to ${steps} in ${work.took}, one event per step.`}
        </p>
      </section>

      <footer className="files">
        Edit <code>src/app.zig</code> for the Zig side and <code>frontend/src/Root.tsx</code> for this window.
        Under <code>plume dev</code>, both reload as you save.
      </footer>
    </main>
  );
}
