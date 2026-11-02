import { useCallback, useEffect, useLayoutEffect, useRef, useState, type MouseEvent } from "react";
// Generated from src/app.zig at every build: App's methods and events, typed.
import { App, Events, Plume, PlumeError, type Item, type Label, type Progress, type Scanned, type Space, type View } from "./bindings";
import { bytes, compact, exact, plural, seconds, share } from "./format";
import { Meter } from "./Meter";

type Phase =
  | { name: "start" }
  | { name: "scanning"; path: string; progress: Progress | null }
  | { name: "ready"; scanned: Scanned }
  | { name: "failed"; path: string; message: string };

export default function Root() {
  const [phase, setPhase] = useState<Phase>({ name: "start" });
  // The home folder's disk until a scan says which one.
  const [space, setSpace] = useState<Space | null>(() => App.space(App.home()));
  const [view, setView] = useState<View | null>(null);
  const [hovered, setHovered] = useState<(Item & { x: number; y: number }) | null>(null);
  const [labelsShown, setLabelsShown] = useState(true);
  const map = useRef<HTMLDivElement>(null);
  const home = useRef(App.home());
  /** The folder on the map, for laying it out again at a new size. */
  const shown = useRef<number | null>(null);

  useEffect(
    () =>
      Events.on("progress", (progress) =>
        setPhase((p) => (p.name === "scanning" ? { ...p, progress } : p)),
      ),
    [],
  );

  /** `node` on the map, laid out for the map's area as it is now. */
  const show = useCallback((node: number) => {
    const area = map.current?.getBoundingClientRect();
    if (!area || area.width < 1 || area.height < 1) return;
    try {
      const next = App.view(node, area.left, area.top, area.width, area.height, window.devicePixelRatio || 1);
      shown.current = node;
      setHovered(null);
      setView(next);
      if (next.zoom_ms > 0) {
        setLabelsShown(false);
        window.setTimeout(() => setLabelsShown(true), next.zoom_ms);
      }
    } catch (error) {
      if (!(error instanceof PlumeError && error.code === "NoScan")) throw error;
    }
  }, []);

  async function scan(path: string) {
    shown.current = null;
    setView(null);
    setHovered(null);
    setSpace(App.space(path));
    setPhase({ name: "scanning", path, progress: null });
    try {
      const scanned = await App.scan(path);
      setPhase({ name: "ready", scanned });
    } catch (error) {
      if (error instanceof PlumeError && error.code === "Canceled") {
        setPhase({ name: "start" });
        return;
      }
      const reasons: Record<string, string> = {
        FileNotFound: "That folder does not exist anymore.",
        NotDir: "That is a file, not a folder.",
        AccessDenied: "Headroom is not allowed to read that folder.",
        OutOfMemory: "There is not enough memory to hold everything in it.",
        Busy: "A scan is already running.",
      };
      const message = error instanceof PlumeError ? (reasons[error.code as string] ?? String(error.code)) : String(error);
      setPhase({ name: "failed", path, message });
    }
  }

  async function choose() {
    const [path] = await Plume.dialog.folder({ title: "Choose a folder to scan", acceptLabel: "Scan" });
    if (path) await scan(path);
  }

  /** The living intro on the map, while there is no treemap to show. */
  const intro = useCallback(() => {
    const area = map.current?.getBoundingClientRect();
    if (area && area.width >= 1 && area.height >= 1)
      App.intro(area.left, area.top, area.width, area.height, window.devicePixelRatio || 1);
  }, []);

  // Once a scan is done, its folder on the map; until then, the intro.
  useLayoutEffect(() => {
    if (phase.name === "ready") show(0);
    else intro();
  }, [phase, show, intro]);

  // The map follows the window's size.
  useEffect(() => {
    const element = map.current;
    if (!element) return;
    let frame = 0;
    const observer = new ResizeObserver(() => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        if (shown.current !== null) show(shown.current);
        else intro();
      });
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, [show, intro]);

  const up = useCallback(() => {
    if (view && view.crumbs.length > 1) show(view.crumbs[view.crumbs.length - 2].node);
  }, [view, show]);

  useEffect(() => {
    function key(event: KeyboardEvent) {
      if ((event.key === "Backspace" || event.key === "Escape") && !(event.target instanceof HTMLInputElement)) up();
    }
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [up]);

  function where(event: MouseEvent) {
    const area = map.current!.getBoundingClientRect();
    return { x: event.clientX - area.left, y: event.clientY - area.top };
  }

  function move(event: MouseEvent) {
    if (!view) return;
    const { x, y } = where(event);
    const item = App.hover(x, y);
    setHovered(item ? { ...item, x, y } : null);
  }

  function leave() {
    App.hover(-1, 0);
    setHovered(null);
  }

  function click(event: MouseEvent) {
    if (event.button !== 0 || !view) return;
    const { x, y } = where(event);
    const item = App.hover(x, y);
    if (item?.opens) show(item.node);
  }

  async function menu(event: MouseEvent) {
    event.preventDefault();
    if (!view) return;
    const { x, y } = where(event);
    const item = App.hover(x, y);
    if (!item) return;
    const folderPath = item.kind === "file" || item.kind === "rest" ? parentOf(item.path, item.kind) : item.path;
    const choice = await Plume.menu.popup(
      [
        ...(item.opens ? [{ id: "open", label: `Open ${item.name}` }] : []),
        { id: "reveal", label: Plume.platform === "windows" ? "Show in Explorer" : "Show in the file manager" },
        { id: "copy", label: "Copy path" },
        ...(view.crumbs.length > 1 ? ["separator" as const, { id: "up", label: "Back up one folder" }] : []),
      ],
      event.clientX,
      event.clientY,
    );
    if (choice === "open") show(item.node);
    if (choice === "reveal") Plume.app.openPath(folderPath);
    if (choice === "copy") Plume.clipboard.writeText(item.path);
    if (choice === "up") up();
  }

  const scanning = phase.name === "scanning";
  const level = scanning ? (phase.progress?.bytes ?? 0) : (view?.size ?? null);

  return (
    <main className="console">
      <header className="deck">
        <div className="deck-row">
          <h1 className="wordmark">Headroom</h1>
          <nav className="crumbs" aria-label="Folder">
            {view ? (
              view.crumbs.map((crumb, i) => (
                <span key={crumb.node} className="crumb-step">
                  {i > 0 && <span className="crumb-sep" aria-hidden="true">/</span>}
                  <button
                    className="crumb"
                    aria-current={i === view.crumbs.length - 1 ? "location" : undefined}
                    onClick={() => show(crumb.node)}
                  >
                    {crumb.name}
                  </button>
                </span>
              ))
            ) : (
              <span className="crumb-idle">{scanning ? phase.path : "No folder scanned"}</span>
            )}
          </nav>
          <div className="deck-actions">
            {phase.name === "ready" && (
              <button className="control" onClick={() => scan(phase.scanned.path)}>
                Scan again
              </button>
            )}
            <button className="control control-main" onClick={choose} disabled={scanning}>
              Choose folder
            </button>
          </div>
        </div>
        <Meter space={space} level={level} scanning={scanning} />
      </header>

      <section
        ref={map}
        className="map"
        aria-label="Treemap"
        onMouseMove={move}
        onMouseLeave={leave}
        onClick={click}
        onContextMenu={menu}
        data-pointer={hovered?.opens ? "open" : undefined}
      >
        {view && (
          <div className="labels" data-shown={labelsShown ? "" : undefined} aria-hidden="true">
            {view.labels.map((label, i) => (
              <MapLabel key={`${view.node}-${i}`} label={label} />
            ))}
          </div>
        )}

        {hovered && labelsShown && <Tooltip item={hovered} />}

        {phase.name === "start" && (
          <div className="stage stage-intro">
            <h2 className="stage-title stage-title-large">See what fills your disk</h2>
            <p className="stage-text">
              Headroom reads every file in a folder and draws them by the space they take. Open folders to go deeper.
            </p>
            <div className="stage-actions">
              {home.current && (
                <button className="control control-main control-large" onClick={() => scan(home.current)}>
                  Scan your home folder
                </button>
              )}
              <button className="control control-large" onClick={() => scan(driveOf(home.current))}>
                Scan the whole disk
              </button>
              <button className="control control-large control-quiet" onClick={choose}>
                Choose a folder
              </button>
            </div>
            {home.current && (
              <p className="stage-note">
                Your home folder is <span className="stage-path">{home.current}</span>. Nothing is changed or deleted.
              </p>
            )}
          </div>
        )}

        {phase.name === "scanning" && (
          <div className="stage stage-intro">
            <p className="count">{exact(phase.progress?.files ?? 0)}</p>
            <p className="stage-text">
              files read in {compact(phase.progress?.folders ?? 0)}{" "}
              {plural(phase.progress?.folders ?? 0, "folder", "folders")}
            </p>
            <div className="stage-actions">
              <button className="control" onClick={() => App.cancelScan()}>
                Stop scanning
              </button>
            </div>
          </div>
        )}

        {phase.name === "failed" && (
          <div className="stage stage-intro">
            <h2 className="stage-title">{phase.path} was not scanned</h2>
            <p className="stage-text">{phase.message}</p>
            <div className="stage-actions">
              <button className="control control-main" onClick={choose}>
                Choose another folder
              </button>
            </div>
          </div>
        )}
      </section>

      <footer className="rack">
        <ul className="legend" aria-label="What the space is">
          {view?.legend.map((entry) => (
            <li key={entry.name} className="legend-entry">
              <span className="swatch" style={{ background: entry.color }} />
              <span className="legend-name">{entry.name}</span>
              <span className="legend-size">{bytes(entry.size)}</span>
            </li>
          ))}
        </ul>
        {phase.name === "ready" && (
          <p className="status">
            {exact(phase.scanned.entries)} entries scanned in {seconds(phase.scanned.ms)}
            {phase.scanned.unreadable > 0 &&
              `, ${exact(phase.scanned.unreadable)} ${plural(phase.scanned.unreadable, "folder", "folders")} not readable`}
          </p>
        )}
      </footer>
    </main>
  );
}

function MapLabel({ label }: { label: Label }) {
  const style = { left: label.x, top: label.y, width: label.w, height: label.h };
  if (label.shape === "folder") {
    return (
      <div className="label label-header" style={style}>
        <span className="label-name">{label.name}</span>
        <span className="label-size">{bytes(label.size)}</span>
      </div>
    );
  }
  const name = label.shape === "rest" ? `${exact(label.count)} smaller items` : label.name;
  return (
    <div className="label label-tile" data-shape={label.shape} style={style}>
      <span className="label-name">{name}</span>
      {label.h >= 44 && <span className="label-size">{bytes(label.size)}</span>}
    </div>
  );
}

function Tooltip({ item }: { item: Item & { x: number; y: number } }) {
  const kind = {
    folder: `${exact(item.files)} ${plural(item.files, "file", "files")}`,
    file: item.category?.name ?? "File",
    link: "A link, not followed",
    mount: "Another disk, not scanned",
    other: "A device or pipe",
    rest: `${exact(item.count)} items too small to draw`,
  }[item.kind];
  // Flip to the left or above near the map's far edges.
  const style = {
    left: item.x + 16,
    top: item.y + 18,
    transform: `translate(${item.x > window.innerWidth - 360 ? "calc(-100% - 32px)" : "0"}, ${item.y > window.innerHeight - 320 ? "calc(-100% - 36px)" : "0"})`,
  };
  return (
    <div className="tooltip" style={style} role="status">
      <p className="tooltip-name">{item.kind === "rest" ? `In ${item.name}` : item.name}</p>
      <p className="tooltip-size">
        {bytes(item.size)} <span className="tooltip-share">{share(item.share)} of this folder</span>
      </p>
      <p className="tooltip-kind">
        {item.category && <span className="swatch" style={{ background: item.category.color }} />}
        {kind}
        {item.unreadable && ", not readable"}
      </p>
      {item.opens && <p className="tooltip-hint">Click to open</p>}
    </div>
  );
}

/** The disk a path is on: "C:\" for "C:\Users\ada", "/" on Linux. */
function driveOf(path: string): string {
  const drive = /^[A-Za-z]:[\\/]/.exec(path);
  return drive ? `${path.slice(0, 2)}\\` : "/";
}

/** The folder a file or the rest is in. */
function parentOf(path: string, kind: Item["kind"]): string {
  if (kind === "rest") return path;
  const cut = Math.max(path.lastIndexOf("\\"), path.lastIndexOf("/"));
  return cut > 0 ? path.slice(0, cut) : path;
}
