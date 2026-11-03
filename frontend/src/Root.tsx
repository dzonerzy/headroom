import { useCallback, useEffect, useLayoutEffect, useRef, useState, type MouseEvent } from "react";
// Generated from src/app.zig at every build: App's methods and events, typed.
import { App, Events, Plume, PlumeError, type Item, type Label, type Progress, type Scanned, type Space, type View } from "./bindings";
import { bytes, compact, exact, plural, seconds, share } from "./format";
import { Mark, Meter } from "./Meter";
import { bin, ConfirmRemove, type Mode } from "./Remove";
import { ConfirmGroup, SidePanel, type Tab } from "./Reclaim";
import { ListView, Search } from "./Find";
import { MachineList } from "./Machine";
import { DupesList } from "./Dupes";
import type { Changed, Dupes, DupesProgress, Group, Place, Reclaim, Removal, Stale } from "./bindings";

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
  const admin = useRef(App.admin());
  const disks = useRef(App.disks());
  // WSL's distributions (the registry: quick); Docker is asked when its tab opens.
  const distros = useRef(App.distros());
  const machineLabel = distros.current.length > 0 ? "WSL & Docker" : "Docker";
  const [elevating, setElevating] = useState(false);
  const [confirm, setConfirm] = useState<{ removal: Removal; mode: Mode; busy: boolean; error: string | null } | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [watching, setWatchingShown] = useState(() => App.watching());
  const [reclaim, setReclaim] = useState<Reclaim | null>(null);
  const [stale, setStale] = useState<Stale | null>(null);
  const [staleDays, setStaleDays] = useState(90);
  // For the ready effect, which runs on a new scan only.
  const staleDaysRef = useRef(staleDays);
  staleDaysRef.current = staleDays;
  const [changed, setChanged] = useState<Changed | null>(null);
  const [dupes, setDupes] = useState<Dupes | null>(null);
  const [finding, setFinding] = useState(false);
  const [dupesProgress, setDupesProgress] = useState<DupesProgress | null>(null);
  const [panel, setPanel] = useState(false);
  const [tab, setTab] = useState<Tab>("reclaim");
  const [listing, setListing] = useState(false);
  const [groupConfirm, setGroupConfirm] = useState<{ group: Group; busy: boolean; error: string | null } | null>(null);

  function openPanel(open: boolean, on: Tab = tab) {
    setPanel(open);
    setTab(on);
    // The map's marks: what can go, while that tab is shown.
    App.showReclaimable(open && on === "reclaim");
  }

  /** The map, the list of what can go and the disk's space, after a change. */
  function refreshAfterChange() {
    if (shown.current !== null) show(shown.current);
    setReclaim(App.reclaimable());
    setStale(App.stale(staleDays));
    setDupes(App.duplicates());
    if (phase.name === "ready" && !phase.scanned.wsl) setSpace(App.space(phase.scanned.path));
  }

  function goTo(place: Place) {
    show(place.parent);
    App.highlight(place.node);
  }

  async function cleanGroup(mode: Mode) {
    if (!groupConfirm || !reclaim) return;
    const { group } = groupConfirm;
    setGroupConfirm({ ...groupConfirm, busy: true, error: null });
    try {
      if (group.action === "empty_bin") {
        const freed = await App.emptyBin(group.nodes[0], reclaim.generation);
        setNotice(`Emptied the ${bin}: ${bytes(freed.size)} freed.`);
      } else {
        const done = await App.removeMany(group.nodes, reclaim.generation, mode);
        const what = `${exact(done.count)} ${plural(done.count, "place", "places")}`;
        const failed = done.failed > 0 ? ` ${exact(done.failed)} could not go (${done.reason ?? "failed"}).` : "";
        setNotice(
          mode === "trash"
            ? `Moved ${what} to the ${bin} (${bytes(done.size)}).${failed}`
            : `Deleted ${what}: ${bytes(done.size)} freed.${failed}`,
        );
      }
      setGroupConfirm(null);
      refreshAfterChange();
    } catch (error) {
      const code = error instanceof PlumeError ? String(error.code) : "Failed";
      setGroupConfirm({
        group,
        busy: false,
        error: code === "Stale" ? "The folder was scanned again since. Try again on the new list." : `It could not be done (${code}).`,
      });
    }
  }

  // Watching free space: the tray's own requests, and its reading once a minute.
  useEffect(() => {
    const offScan = Events.on("request_scan", (path) => void scan(path));
    const offWatching = Events.on("watching", (on) => setWatchingShown(on));
    const timer = window.setInterval(() => App.watchTick(), 60_000);
    return () => {
      offScan();
      offWatching();
      window.clearInterval(timer);
    };
    // scan only uses setters and refs.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function toggleWatching() {
    try {
      App.setWatching(!watching);
      setWatchingShown(!watching);
      setNotice(
        watching
          ? "Headroom stopped watching free space."
          : `Headroom watches free space from the tray now, and tells you when a disk has less than ${App.alarm()}% free. Closing the window keeps it there.`,
      );
    } catch {
      setNotice("This desktop has no tray: Headroom cannot watch free space from there.");
    }
  }

  // A notice stays a few seconds.
  useEffect(() => {
    if (!notice) return;
    const timer = window.setTimeout(() => setNotice(null), 6000);
    return () => window.clearTimeout(timer);
  }, [notice]);

  /** Asks before deleting `node`. */
  function askRemove(node: number, mode: Mode = "trash") {
    const removal = App.removal(node);
    if (removal.refused) {
      setNotice(`${removal.name} cannot be deleted: ${removal.refused}.`);
      return;
    }
    setConfirm({ removal, mode, busy: false, error: null });
  }

  async function remove() {
    if (!confirm) return;
    const { removal, mode } = confirm;
    setConfirm({ ...confirm, busy: true, error: null });
    try {
      const removed = await App.remove(removal.node, removal.generation, mode);
      setConfirm(null);
      refreshAfterChange();
      setNotice(
        mode === "trash"
          ? `Moved ${removal.name} to the ${bin} (${bytes(removed.size)}). Empty the ${bin} to get the space back.`
          : `Deleted ${removal.name}: ${bytes(removed.size)} freed.`,
      );
    } catch (error) {
      const code = error instanceof PlumeError ? String(error.code) : "Failed";
      const reasons: Record<string, string> = {
        InUse: "Another program has it open. Close that program and try again.",
        AccessDenied: admin.current
          ? "Even an administrator is not allowed to delete it."
          : "Headroom is not allowed to delete it. Scanning as administrator may let it.",
        NotFound: "It is not there anymore.",
        TrashUnavailable: `It cannot go to the ${bin} (another disk, or too long a path). It can be deleted permanently instead.`,
        Refused: "Headroom does not delete this.",
        Stale: "The folder was scanned again since. Try again on the new map.",
        Failed: "It could not be deleted.",
      };
      setConfirm({
        removal,
        mode: code === "TrashUnavailable" ? "permanent" : mode,
        busy: false,
        error: reasons[code] ?? reasons.Failed,
      });
    }
  }

  // Restarted as administrator to scan a folder again: scan it now.
  useEffect(() => {
    const path = App.startupScan();
    if (path) void scan(path);
    // Once, at the start.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(
    () =>
      Events.on("progress", (progress) =>
        setPhase((p) => (p.name === "scanning" ? { ...p, progress } : p)),
      ),
    [],
  );
  useEffect(() => Events.on("duplicates", (progress) => setDupesProgress(progress)), []);

  /** The duplicates in the last scan, read on a worker thread. */
  async function findDuplicates() {
    setFinding(true);
    setDupesProgress(null);
    try {
      setDupes(await App.findDuplicates());
    } catch (error) {
      const code = error instanceof PlumeError ? String(error.code) : "Failed";
      if (code !== "Canceled") setNotice(code === "Busy" ? "Wait for the scan to end, then look for duplicates." : `Duplicates could not be found (${code}).`);
    } finally {
      setFinding(false);
    }
  }

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

  /** The same scan again: a WSL distribution through its own find, as the
   * first time (its folders over WSL's share would be slow, /mnt/c in them). */
  function rescan(scanned: Scanned) {
    const distro = scanned.wsl ? scanned.path.replace(/^\\\\wsl(\.localhost|\$)\\/i, "") : undefined;
    void scan(scanned.path, distro);
  }

  /** A folder, or with `distro` everything inside that WSL distribution. */
  async function scan(path: string, distro?: string) {
    shown.current = null;
    setView(null);
    setHovered(null);
    if (!distro) setSpace(App.space(path));
    setPhase({ name: "scanning", path, progress: null });
    try {
      const scanned = distro ? await App.scanDistro(distro) : await App.scan(path);
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
        NoWsl: "WSL is not available.",
        Failed: "The distribution could not be read (is it installed and working?).",
      };
      const message = error instanceof PlumeError ? (reasons[error.code as string] ?? String(error.code)) : String(error);
      setPhase({ name: "failed", path, message });
    }
  }

  /** Headroom again as administrator, scanning `path`; this one quits. */
  function scanAsAdmin(path: string) {
    setElevating(true);
    try {
      App.restartAsAdmin(path);
      Plume.app.quit();
    } catch {
      // The prompt declined: nothing changes.
      setElevating(false);
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

  // Once a scan is done, its folder on the map and what can go; until then,
  // the intro.
  useLayoutEffect(() => {
    if (phase.name === "ready") {
      show(0);
      setReclaim(App.reclaimable());
      setStale(App.stale(staleDaysRef.current));
      setChanged(App.changed());
      setDupes(null);
    } else {
      intro();
      setReclaim(null);
      setStale(null);
      setDupes(null);
      setChanged(null);
      setPanel(false);
      App.showReclaimable(false);
    }
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
      // Typing in a field is not a command.
      if (event.target instanceof HTMLInputElement) return;
      if (confirm) {
        if (event.key === "Escape" && !confirm.busy) setConfirm(null);
        return;
      }
      if (event.key === "Delete" && hovered && hovered.kind !== "rest") {
        askRemove(hovered.node, event.shiftKey ? "permanent" : "trash");
        return;
      }
      if ((event.key === "Backspace" || event.key === "Escape") && !(event.target instanceof HTMLInputElement)) up();
    }
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
    // askRemove reads the current state.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [up, confirm, hovered]);

  function where(event: MouseEvent) {
    const area = map.current!.getBoundingClientRect();
    return { x: event.clientX - area.left, y: event.clientY - area.top };
  }

  function move(event: MouseEvent) {
    if (!view || listing) return;
    const { x, y } = where(event);
    const item = App.hover(x, y);
    setHovered(item ? { ...item, x, y } : null);
  }

  function leave() {
    App.hover(-1, 0);
    setHovered(null);
  }

  function click(event: MouseEvent) {
    if (event.button !== 0 || !view || listing) return;
    const { x, y } = where(event);
    const item = App.hover(x, y);
    if (item?.opens) show(item.node);
  }

  async function menu(event: MouseEvent) {
    event.preventDefault();
    if (!view || listing) return;
    const { x, y } = where(event);
    const item = App.hover(x, y);
    if (!item) return;
    const folderPath = item.kind === "file" || item.kind === "rest" ? parentOf(item.path, item.kind) : item.path;
    const removal = item.kind === "rest" ? null : App.removal(item.node);
    const choice = await Plume.menu.popup(
      [
        ...(item.opens ? [{ id: "open", label: `Open ${item.name}` }] : []),
        { id: "reveal", label: Plume.platform === "windows" ? "Show in Explorer" : "Show in the file manager" },
        { id: "copy", label: "Copy path" },
        ...(removal
          ? [
              "separator" as const,
              ...(removal.refused
                ? [{ id: "refused", label: `Cannot delete: ${removal.refused}`, enabled: false }]
                : [
                    { id: "trash", label: `Move to the ${bin}…`, accelerator: "Delete" },
                    { id: "permanent", label: "Delete permanently…", accelerator: "Shift+Delete" },
                  ]),
            ]
          : []),
        ...(view.crumbs.length > 1 ? ["separator" as const, { id: "up", label: "Back up one folder" }] : []),
      ],
      event.clientX,
      event.clientY,
    );
    if (choice === "open") show(item.node);
    if (choice === "reveal") Plume.app.openPath(folderPath);
    if (choice === "copy") Plume.clipboard.writeText(item.path);
    if (choice === "trash" || choice === "permanent") askRemove(item.node, choice);
    if (choice === "up") up();
  }

  const scanning = phase.name === "scanning";
  const level = scanning ? (phase.progress?.bytes ?? 0) : (view?.size ?? null);

  return (
    <main className="console">
      <header className="deck">
        <div className="deck-row">
          <h1 className="wordmark">
            <Mark />
            Headroom
            {admin.current && <span className="wordmark-mode">as administrator</span>}
          </h1>
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
          {view && <Search onPick={(found) => goTo({ node: found.node, parent: found.parent, path: found.path, size: found.size })} />}
          <div className="deck-actions">
            {changed && Math.abs(changed.after - changed.before) >= 64 * 1024 * 1024 && (
              <button
                className="control control-quiet control-changed"
                data-sign={changed.after >= changed.before ? "up" : "down"}
                aria-pressed={panel && tab === "changed"}
                onClick={() => openPanel(!(panel && tab === "changed"), "changed")}
              >
                {changed.after >= changed.before ? "+" : "−"}
                {bytes(Math.abs(changed.after - changed.before))} since{" "}
                {new Date(changed.since_ms).toLocaleDateString(undefined, { day: "numeric", month: "short" })}
              </button>
            )}
            {reclaim && reclaim.size > 0 && (
              <button
                className="control control-reclaim"
                aria-pressed={panel && tab === "reclaim"}
                onClick={() => openPanel(!(panel && tab === "reclaim"), "reclaim")}
              >
                <span className="led" data-on="" aria-hidden="true" />
                {bytes(reclaim.size)} can go
              </button>
            )}
            <button
              className="control control-quiet control-machine"
              aria-pressed={panel && tab === "machine"}
              onClick={() => openPanel(!(panel && tab === "machine"), "machine")}
            >
              {machineLabel}
            </button>
            {stale && stale.size > 0 && (
              <button
                className="control control-quiet control-stale"
                aria-pressed={panel && tab === "stale"}
                onClick={() => openPanel(!(panel && tab === "stale"), "stale")}
              >
                {bytes(stale.size)} in old projects
              </button>
            )}
            <button
              className="control control-quiet control-watch"
              aria-pressed={watching}
              onClick={toggleWatching}
              title="Watch free space from the tray, and get told when a disk is nearly full"
            >
              <span className="led" data-on={watching ? "" : undefined} aria-hidden="true" />
              Watch free space
            </button>
            {phase.name === "ready" && (
              <button className="control control-rescan" onClick={() => rescan(phase.scanned)}>
                Scan again
              </button>
            )}
            <button className="control control-main" onClick={choose} disabled={scanning}>
              Choose folder
            </button>
          </div>
        </div>
        <Meter
          space={space}
          level={level}
          scanning={scanning}
          focus={hovered && hovered.kind !== "rest" ? { name: hovered.name, size: hovered.size } : null}
        />
      </header>

      <div className="workspace">
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
          <div
            className="viewswitch"
            role="radiogroup"
            aria-label="Show as"
            onClick={(event) => event.stopPropagation()}
            onMouseMove={(event) => event.stopPropagation()}
          >
            <button role="radio" aria-checked={!listing} className="viewswitch-option" onClick={() => setListing(false)}>
              Map
            </button>
            <button role="radio" aria-checked={listing} className="viewswitch-option" onClick={() => setListing(true)}>
              List
            </button>
          </div>
        )}
        {view && listing && (
          <ListView view={view} onOpen={(node) => show(node)} onHover={(node) => (node === null ? App.hover(-1, 0) : App.highlight(node))} />
        )}
        {view && !listing && (
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
              {disks.current.length <= 1 && (
                <button className="control control-large" onClick={() => scan(driveOf(home.current))}>
                  Scan the whole disk
                </button>
              )}
              <button className="control control-large control-quiet" onClick={choose}>
                Choose a folder
              </button>
            </div>
            {disks.current.length > 1 && (
              <ul className="disks" aria-label="Scan a whole disk">
                {disks.current.map((disk) => (
                  <li key={disk.path}>
                    <button className="disk" onClick={() => scan(disk.path)}>
                      <span className="disk-name">
                        {disk.name} <span className="disk-path">{disk.path}</span>
                      </span>
                      <span className="disk-track">
                        <span className="disk-used" data-low={disk.free / disk.total < 0.1 ? "" : undefined} style={{ width: `${((disk.total - disk.free) / disk.total) * 100}%` }} />
                      </span>
                      <span className="disk-free">{bytes(disk.free)} free of {bytes(disk.total)}</span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
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

      {panel && (
        <SidePanel
          tab={tab}
          onTab={(on) => openPanel(true, on)}
          changed={changed}
          onGoTo={(parent, node) => {
            show(parent);
            App.highlight(node);
          }}
          reclaim={reclaim}
          stale={stale}
          staleDays={staleDays}
          onStaleDays={(days) => {
            setStaleDays(days);
            setStale(App.stale(days));
          }}
          busy={groupConfirm?.busy ? groupConfirm.group.id : null}
          onClean={(group) => setGroupConfirm({ group, busy: false, error: null })}
          onCopy={(command) => {
            Plume.clipboard.writeText(command);
            setNotice(`Copied: ${command}. Run it in a terminal, then scan again.`);
          }}
          onGo={goTo}
          onHover={(place) => (place ? App.highlight(place.node) : App.hover(-1, 0))}
          onClose={() => openPanel(false)}
          dupes={
            phase.name === "ready" ? (
              <DupesList
                dupes={dupes}
                finding={finding}
                progress={dupesProgress}
                busy={groupConfirm?.busy ? groupConfirm.group.id : null}
                onFind={() => void findDuplicates()}
                onCancel={() => App.cancelScan()}
                onClean={(group) => setGroupConfirm({ group, busy: false, error: null })}
                onGo={goTo}
              />
            ) : null
          }
          machine={{
            label: machineLabel,
            content: (
              <MachineList
                distros={distros.current}
                admin={admin.current}
                onLookInside={(distro) => {
                  openPanel(false);
                  void scan(`\\\\wsl.localhost\\${distro.name}`, distro.name);
                }}
                onNotice={setNotice}
                onAdmin={() => scanAsAdmin(home.current)}
              />
            ),
          }}
        />
      )}
      </div>

      {groupConfirm && (
        <ConfirmGroup
          group={groupConfirm.group}
          busy={groupConfirm.busy}
          error={groupConfirm.error}
          noBin={phase.name === "ready" && phase.scanned.wsl}
          onConfirm={cleanGroup}
          onCancel={() => setGroupConfirm(null)}
        />
      )}
      {confirm && (
        <ConfirmRemove
          removal={confirm.removal}
          mode={confirm.mode}
          busy={confirm.busy}
          error={confirm.error}
          onMode={(mode) => setConfirm({ ...confirm, mode, error: null })}
          onConfirm={remove}
          onCancel={() => setConfirm(null)}
        />
      )}
      {notice && (
        <p className="notice" role="status">
          {notice}
        </p>
      )}

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
          <Hidden scanned={phase.scanned} space={space} admin={admin.current} elevating={elevating} onElevate={scanAsAdmin} />
        )}
      </footer>
    </main>
  );
}

/** How the scan went, and what it could not see. After a whole disk scanned
 * without administrator rights (Windows), what the disk says is used but
 * the scan did not find is behind folders only an administrator can read:
 * said, with a way to scan again as one. */
function Hidden(props: {
  scanned: Scanned;
  space: Space | null;
  admin: boolean;
  elevating: boolean;
  onElevate: (path: string) => void;
}) {
  const { scanned, space, admin, elevating, onElevate } = props;
  const wholeDisk = /^[A-Za-z]:\\$/.test(scanned.path) || scanned.path === "/";
  const used = space ? space.total - space.free : 0;
  const missing = used - scanned.size;
  const offer = Plume.platform === "windows" && !admin && wholeDisk && scanned.unreadable > 0 && missing > 1024 ** 3;
  const summary = scanned.from_mft
    ? `${exact(scanned.entries)} entries read from the disk's file table in ${seconds(scanned.ms)}`
    : `${exact(scanned.entries)} entries scanned in ${seconds(scanned.ms)}`;
  if (offer) {
    return (
      <div className="hidden-space">
        <p className="status">
          {summary}. <span className="status-strong">{bytes(missing)}</span> of the disk is in{" "}
          {exact(scanned.unreadable)} {plural(scanned.unreadable, "folder", "folders")} only an administrator can read.
        </p>
        <button className="control" onClick={() => onElevate(scanned.path)} disabled={elevating}>
          Scan again as administrator
        </button>
      </div>
    );
  }
  return (
    <p className="status">
      {summary}
      {scanned.unreadable > 0 &&
        `, ${exact(scanned.unreadable)} ${plural(scanned.unreadable, "folder", "folders")} not readable`}
    </p>
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
