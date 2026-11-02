import { useCallback, useEffect, useState } from "react";
import { App, Plume, type Space, type Top } from "./bindings";
import { bytes, bytesParts, share } from "./format";
import { Mark } from "./Meter";

/** Segments of the small meter, and where its clip zone starts. */
const SEGMENTS = 32;
const CLIP_FROM = Math.round(SEGMENTS * 0.9);
/** Below this share free, the alarm (as src/app.zig's alarm_below). */
const ALARM_BELOW = 0.1;

type Reading = { space: Space | null; top: Top[]; scanned: string | null; drive: string };

function read(): Reading {
  const home = App.home();
  return { space: App.space(home), top: App.largest(4), scanned: App.scannedPath(), drive: driveOf(home) };
}

/** The tray's popover: the disk's headroom at a glance, the alarm, what
 * filled it at the last scan, and the way into Headroom. */
export default function Popover() {
  const [reading, setReading] = useState<Reading>(read);
  const refresh = useCallback(() => setReading(read()), []);

  useEffect(() => {
    // Fresh each time it is shown (it takes the focus), and while open.
    const off = Plume.window.on("focus", (focused) => focused && refresh());
    const timer = window.setInterval(refresh, 30_000);
    const key = (event: KeyboardEvent) => event.key === "Escape" && App.hidePopover();
    window.addEventListener("keydown", key);
    return () => {
      off();
      window.clearInterval(timer);
      window.removeEventListener("keydown", key);
    };
  }, [refresh]);

  const { space, top, scanned, drive } = reading;
  const free = space ? space.free / space.total : 1;
  const low = free < ALARM_BELOW;
  const used = space ? ((space.total - space.free) / space.total) * SEGMENTS : 0;
  const [value, unit] = bytesParts(space?.free ?? 0);
  const biggest = top[0]?.size ?? 1;

  return (
    <main className="popover" data-low={low ? "" : undefined}>
      <header className="popover-head">
        <span className="popover-brand">
          <Mark />
          Headroom
        </span>
        <span className="popover-watch">
          <span className="led" data-on="" aria-hidden="true" />
          Watching
        </span>
      </header>

      <section className="popover-reading" aria-label="Free space">
        <p className="figure popover-figure">
          <span className="figure-value">{value}</span>
          <span className="figure-unit">{unit}</span>
        </p>
        <p className="figure-caption">
          headroom on {drive}
          {space && `, ${share(free)} of ${bytes(space.total)}`}
        </p>
        <div className="segments popover-segments" role="meter" aria-label="Disk used" aria-valuemin={0} aria-valuemax={space?.total ?? 0} aria-valuenow={space ? space.total - space.free : 0}>
          {Array.from({ length: SEGMENTS }, (_, i) => (
            <span key={i} className="segment" data-state={i < used ? "lit" : "free"} data-clip={i >= CLIP_FROM ? "" : undefined} />
          ))}
        </div>
        <p className="popover-alarm">
          {low
            ? "Less than a tenth of the disk is free. Open Headroom to see what fills it."
            : "You are told when less than a tenth of the disk is free."}
        </p>
      </section>

      <section className="popover-top" aria-label="Largest at the last scan">
        {scanned && top.length > 0 ? (
          <>
            <h2 className="popover-label" title={scanned}>
              Largest in {nameOf(scanned)}
            </h2>
            <ul className="popover-list">
              {top.map((entry) => (
                <li key={entry.name} className="popover-entry">
                  <span className="popover-name">{entry.name}</span>
                  <span className="popover-size">{bytes(entry.size)}</span>
                  <span className="popover-bar" style={{ width: `${Math.max(3, (entry.size / biggest) * 100)}%` }} />
                </li>
              ))}
            </ul>
          </>
        ) : (
          <p className="popover-empty">Scan a folder to see what fills it.</p>
        )}
      </section>

      <footer className="popover-actions">
        <button className="control control-main" onClick={() => App.openMain()}>
          Open Headroom
        </button>
        <button className="control" onClick={() => App.requestScan(drive)}>
          Scan the whole disk
        </button>
      </footer>
    </main>
  );
}

/** A folder's own name: "ada" for "C:\Users\ada", the disk for its root. */
function nameOf(path: string): string {
  const parts = path.split(/[\\/]/).filter(Boolean);
  return parts.length > 1 ? parts[parts.length - 1] : path;
}

/** "C:\" for "C:\Users\ada", "/" on Linux. */
function driveOf(path: string): string {
  return /^[A-Za-z]:[\\/]/.test(path) ? `${path.slice(0, 2)}\\` : "/";
}
