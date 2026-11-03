import { useCallback, useEffect, useState } from "react";
import { App, Plume, type Disk, type FreeHistory, type Space, type Top } from "./bindings";
import { bytes, bytesParts, share } from "./format";
import { Mark } from "./Meter";

/** The alarm's choices, percent free. */
const ALARMS = [5, 10, 15, 20];

type Reading = { space: Space | null; top: Top[]; scanned: string | null; drive: string; alarm: number; others: Disk[]; trend: FreeHistory | null };

function read(): Reading {
  const home = App.home();
  const drive = driveOf(home);
  const others = App.disks().filter((d) => d.path.toLowerCase() !== drive.toLowerCase() && !d.removable);
  return {
    space: App.space(home),
    top: App.largest(others.length > 0 ? 3 : 4),
    scanned: App.scannedPath(),
    drive,
    alarm: App.alarm(),
    others,
    trend: App.freeHistory(drive),
  };
}

/** Less than this lost today is not said. */
const LOST_TOLD = 1e9;

/** The tray's popover: the disk as an arc meter with its headroom in the
 * middle, the alarm, what filled it at the last scan, the way into
 * Headroom. */
export default function Popover() {
  const [reading, setReading] = useState<Reading>(read);
  // Bumped each time it is shown: the arc sweeps up again.
  const [shown, setShown] = useState(0);
  const refresh = useCallback(() => {
    setReading(read());
    setShown((n) => n + 1);
  }, []);

  useEffect(() => {
    const off = Plume.window.on("focus", (focused) => focused && refresh());
    const timer = window.setInterval(() => setReading(read()), 30_000);
    const key = (event: KeyboardEvent) => event.key === "Escape" && App.hidePopover();
    window.addEventListener("keydown", key);
    return () => {
      off();
      window.clearInterval(timer);
      window.removeEventListener("keydown", key);
    };
  }, [refresh]);

  const { space, top, scanned, drive, alarm, others, trend } = reading;
  const free = space ? space.free / space.total : 1;
  const low = free < alarm / 100;
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
          Watching {drive}
        </span>
      </header>

      <section className="popover-gauge" aria-label="Free space">
        <Arc used={1 - free} sweep={shown} alarm={alarm / 100} />
        <div className="popover-reading">
          <p className="figure popover-figure">
            <span className="figure-value">{value}</span>
            <span className="figure-unit">{unit}</span>
          </p>
          <p className="popover-caption">
            headroom{space && `, ${share(free)} of ${bytes(space.total)}`}
          </p>
        </div>
      </section>

      {trend && trend.points.length > 1 && <Trend trend={trend} />}

      <div className="popover-alarm">
        {low && <p className="popover-warning">Less than {alarm}% of {drive} is free.</p>}
        <span className="popover-alarm-label">Tell me below</span>
        <span className="popover-choices" role="radiogroup" aria-label="Alarm below">
          {ALARMS.map((percent) => (
            <button
              key={percent}
              className="popover-choice"
              role="radio"
              aria-checked={percent === alarm}
              onClick={() => {
                App.setAlarm(percent);
                setReading(read());
              }}
            >
              {percent}%
            </button>
          ))}
        </span>
      </div>

      {others.length > 0 && (
        <ul className="popover-disks" aria-label="Other disks">
          {others.map((disk) => (
            <li key={disk.path} className="popover-disk" data-low={disk.free / disk.total < alarm / 100 ? "" : undefined}>
              <span className="popover-disk-name">
                {disk.name} <span className="disk-path">{disk.path}</span>
              </span>
              <span className="popover-disk-free">{bytes(disk.free)} free</span>
              <span className="disk-track">
                <span className="disk-used" data-low={disk.free / disk.total < alarm / 100 ? "" : undefined} style={{ width: `${((disk.total - disk.free) / disk.total) * 100}%` }} />
              </span>
            </li>
          ))}
        </ul>
      )}

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
                  <span className="popover-track">
                    <span className="popover-bar" style={{ width: `${Math.max(2, (entry.size / biggest) * 100)}%` }} />
                  </span>
                </li>
              ))}
            </ul>
          </>
        ) : (
          <p className="popover-empty">Scan a folder to see what fills it.</p>
        )}
      </section>

      <footer className="popover-actions">
        <button className="control control-main popover-open" onClick={() => App.openMain()}>
          Open Headroom
        </button>
        <button className="control control-quiet popover-scan" onClick={() => App.requestScan(drive)}>
          Scan the whole disk
        </button>
      </footer>
    </main>
  );
}

/** The disk's free space over the last two weeks, a line from the oldest
 * sample to now, and what it lost today when that is worth saying. */
function Trend({ trend }: { trend: FreeHistory }) {
  const W = 300;
  const H = 36;
  const { points } = trend;
  const first = points[0].time;
  const span = Math.max(points[points.length - 1].time - first, 1);
  const frees = points.map((p) => p.free);
  const low = Math.min(...frees);
  const high = Math.max(...frees);
  // A flat line sits in the middle; otherwise the range fills the height.
  const range = Math.max(high - low, trend.total / 200, 1);
  const mid = (high + low) / 2;
  const line = points
    .map((p) => `${((p.time - first) / span) * W},${H / 2 - ((p.free - mid) / range) * (H - 6)}`)
    .join(" ");
  const days = Math.max(1, Math.round(span / 86400));
  const fell = trend.lost_today >= LOST_TOLD;
  return (
    <figure className="popover-trend" data-fell={fell ? "" : undefined}>
      <svg className="trend" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" role="img" aria-label={`Free space over the last ${days} days`}>
        <polyline className="trend-line" points={line} vectorEffect="non-scaling-stroke" />
      </svg>
      <figcaption className="popover-trend-caption">
        <span>Free space, {days === 1 ? "today" : `last ${days} days`}</span>
        {fell && <span className="popover-trend-lost">−{bytes(trend.lost_today)} today</span>}
      </figcaption>
    </figure>
  );
}

/** Segments of the arc, its sweep (degrees) and the gap between segments. */
const SEGMENTS = 40;
const SWEEP = 220;
const GAP = 1.6;
const CX = 150;
const CY = 150;
const OUTER = 138;
const INNER = 116;

/** The disk as a VU meter's arc: used space lit, the last tenth the clip
 * zone, a mark where the alarm starts. It sweeps up to the level each time
 * the popover is shown (not with reduced motion). */
function Arc({ used, sweep, alarm }: { used: number; sweep: number; alarm: number }) {
  const target = Math.round(used * SEGMENTS);
  const [lit, setLit] = useState(target);

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setLit(target);
      return;
    }
    const start = performance.now();
    let frame = requestAnimationFrame(function step(now) {
      const t = Math.min((now - start) / 650, 1);
      // Ease out: quick, then settling on the level.
      setLit(Math.round(target * (1 - Math.pow(1 - t, 3))));
      if (t < 1) frame = requestAnimationFrame(step);
    });
    return () => cancelAnimationFrame(frame);
  }, [target, sweep]);

  const clipFrom = Math.round(SEGMENTS * (1 - alarm));
  const step = (SWEEP - GAP * (SEGMENTS - 1)) / SEGMENTS;
  const first = 90 + SWEEP / 2;
  const alarmAt = first - clipFrom * (step + GAP) + GAP / 2;
  return (
    <svg className="arc" viewBox="-12 0 324 206" role="presentation" data-level={target} data-lit={lit}>
      <defs>
        <filter id="arc-glow" x="-20%" y="-20%" width="140%" height="140%">
          <feGaussianBlur stdDeviation="2.4" result="blur" />
          <feMerge>
            <feMergeNode in="blur" />
            <feMergeNode in="SourceGraphic" />
          </feMerge>
        </filter>
      </defs>
      {Array.from({ length: SEGMENTS }, (_, i) => {
        const from = first - i * (step + GAP);
        const on = i < lit;
        const clip = i >= clipFrom;
        return (
          <path
            key={i}
            d={sector(from, from - step)}
            className="arc-segment"
            data-on={on ? "" : undefined}
            data-clip={clip ? "" : undefined}
            filter={on ? "url(#arc-glow)" : undefined}
          />
        );
      })}
      {/* Where the alarm starts. */}
      <line className="arc-alarm" {...ray(alarmAt, INNER - 9, INNER - 3)} />
      <text className="arc-label arc-label-alarm" {...at(alarmAt + 4, INNER - 16)} textAnchor="end">
        alarm
      </text>
      <text className="arc-label" {...at(first - 3, OUTER + 14)} textAnchor="middle">
        0
      </text>
      <text className="arc-label" {...at(first - SWEEP + 3, OUTER + 14)} textAnchor="middle">
        full
      </text>
    </svg>
  );
}

function polar(degrees: number, radius: number) {
  const a = (degrees * Math.PI) / 180;
  return { x: CX + radius * Math.cos(a), y: CY - radius * Math.sin(a) };
}

/** An arc segment from angle `a` to `b` (degrees, counterclockwise from
 * the right, a > b: drawn clockwise). */
function sector(a: number, b: number): string {
  const o1 = polar(a, OUTER);
  const o2 = polar(b, OUTER);
  const i2 = polar(b, INNER);
  const i1 = polar(a, INNER);
  return `M${o1.x},${o1.y} A${OUTER},${OUTER} 0 0 1 ${o2.x},${o2.y} L${i2.x},${i2.y} A${INNER},${INNER} 0 0 0 ${i1.x},${i1.y} Z`;
}

function ray(degrees: number, from: number, to: number) {
  const p = polar(degrees, from);
  const q = polar(degrees, to);
  return { x1: p.x, y1: p.y, x2: q.x, y2: q.y };
}

function at(degrees: number, radius: number) {
  const p = polar(degrees, radius);
  return { x: p.x, y: p.y, dominantBaseline: "middle" as const };
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
