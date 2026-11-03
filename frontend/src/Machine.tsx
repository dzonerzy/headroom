import { useEffect, useRef, useState } from "react";
import { App, PlumeError, type Distro, type Prune, type Usage } from "./bindings";
import { bytes, bytesParts, exact, plural } from "./format";

/** What runs after a confirmation: a distribution's disk compacted, or a
 * Docker prune. */
type Pending =
  | { kind: "compact"; distro: Distro }
  | { kind: "prune"; prune: Prune; size: number; items: string[]; total: number };

const prunes: Record<Prune, { title: string; button: string; note: string; command: string }> = {
  containers: {
    title: "Remove the stopped containers?",
    button: "Remove them",
    note: "Containers that are not running, and what they wrote inside them. Their images and volumes stay.",
    command: "docker container prune --force",
  },
  images: {
    title: "Remove the images no container uses?",
    button: "Remove them",
    note: "Pulled or built again when needed. Images a container uses, running or not, stay.",
    command: "docker image prune --all --force",
  },
  build_cache: {
    title: "Clear Docker's build cache?",
    button: "Clear it",
    note: "Layers kept to build faster: the next builds are slower, then fill it again.",
    command: "docker builder prune --all --force",
  },
};

/** WSL's distributions (each a virtual disk: look inside, compact it) and
 * Docker's disk (images, containers, the build cache, volumes). */
export function MachineList(props: {
  distros: Distro[];
  admin: boolean;
  onLookInside: (distro: Distro) => void;
  onNotice: (text: string) => void;
  onAdmin: () => void;
}) {
  const { distros, admin, onLookInside, onNotice, onAdmin } = props;
  const [usage, setUsage] = useState<Usage | null>(null);
  const [dockerError, setDockerError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [pending, setPending] = useState<Pending | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function loadDocker() {
    setLoading(true);
    try {
      setUsage(await App.dockerUsage());
      setDockerError(null);
    } catch (e) {
      const code = e instanceof PlumeError ? String(e.code) : "Failed";
      setUsage(null);
      setDockerError(
        code === "NoDocker"
          ? "Docker is not installed."
          : code === "NotRunning"
            ? "Docker is not running (or Headroom may not talk to it). Start it, then look again."
            : "Docker did not answer.",
      );
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void loadDocker();
  }, []);

  async function confirm() {
    if (!pending) return;
    setBusy(true);
    setError(null);
    try {
      if (pending.kind === "compact") {
        const done = await App.compactDistro(pending.distro.name);
        onNotice(`${pending.distro.name}'s disk: ${bytes(done.before)} then, ${bytes(done.after)} now (${bytes(Math.max(0, done.before - done.after))} back to Windows).`);
      } else {
        const freed = await App.dockerPrune(pending.prune);
        onNotice(`Docker reclaimed ${bytes(freed)}.`);
        void loadDocker();
      }
      setPending(null);
    } catch (e) {
      const code = e instanceof PlumeError ? String(e.code) : "Failed";
      setError(
        code === "NotAdmin"
          ? "Compacting needs administrator."
          : code === "NotRunning"
            ? "Docker stopped answering."
            : code === "Busy"
              ? "A scan is running: wait for it, then try again."
              : `It could not be done (${code}).`,
      );
    } finally {
      setBusy(false);
    }
  }

  const unusedImages = usage?.image_list.filter((i) => !i.used) ?? [];
  const stopped = usage?.container_list.filter((c) => !c.running) ?? [];
  const reclaimable = usage ? usage.images.reclaimable + usage.containers.reclaimable + usage.build_cache.reclaimable : 0;
  const [value, unit] = bytesParts(distros.reduce((sum, d) => sum + d.size, 0) + (usage ? usage.images.size + usage.containers.size + usage.build_cache.size + usage.volumes.size : 0));

  return (
    <div className="side-body">
      <header className="reclaim-head">
        <div>
          <p className="figure reclaim-figure">
            <span className="figure-value">{value}</span>
            <span className="figure-unit">{unit}</span>
          </p>
          <p className="reclaim-caption">
            in {distros.length > 0 && <>WSL's {plural(distros.length, "distribution", "distributions")}{usage ? " and " : ""}</>}
            {usage && "Docker"}
            {reclaimable > 0 && <>; Docker can give back {bytes(reclaimable)}</>}
          </p>
        </div>
      </header>
      <div className="reclaim-groups">
        {distros.length > 0 && (
          <section className="machine-section">
            <h3 className="changes-label">WSL</h3>
            <p className="reclaim-why machine-note">
              Each distribution is a virtual disk that grows as files are written and never shrinks by itself: look inside to clear what
              can go, then compact it to give the space back to Windows.
            </p>
            <ul>
              {distros.map((distro) => (
                <li key={distro.name} className="reclaim-group machine-distro" data-risk="careful">
                  <div className="reclaim-row">
                    <span className="led reclaim-led" data-risk="careful" aria-hidden="true" />
                    <span className="reclaim-title">{distro.name}</span>
                    <span className="reclaim-size">{bytes(distro.size)}</span>
                  </div>
                  {distro.version === 1 && <p className="reclaim-why">WSL 1: its files are in a folder of Windows, not a virtual disk.</p>}
                  <div className="reclaim-actions">
                    <button className="control reclaim-do" onClick={() => onLookInside(distro)} title="Starts the distribution if it is stopped">
                      Look inside
                    </button>
                    {distro.version === 2 && (
                      <button className="control control-quiet reclaim-more" onClick={() => setPending({ kind: "compact", distro })}>
                        Compact
                      </button>
                    )}
                  </div>
                </li>
              ))}
            </ul>
          </section>
        )}
        <section className="machine-section">
          <h3 className="changes-label">Docker</h3>
          {loading ? (
            <p className="reclaim-empty">Asking Docker…</p>
          ) : dockerError ? (
            <p className="reclaim-empty">{dockerError}</p>
          ) : (
            usage && (
              <ul>
                <DockerRow
                  title="Images"
                  size={usage.images.size}
                  detail={`${exact(usage.images.count)} ${plural(usage.images.count, "image", "images")}, ${exact(unusedImages.length)} not used by any container`}
                  reclaim={usage.images.reclaimable}
                  action={unusedImages.length > 0 ? "Remove unused" : null}
                  onAction={() =>
                    setPending({ kind: "prune", prune: "images", size: usage.images.reclaimable, items: unusedImages.map((i) => `${i.name}  ${bytes(i.size)}`), total: unusedImages.length })
                  }
                />
                <DockerRow
                  title="Containers"
                  size={usage.containers.size}
                  detail={`${exact(usage.containers.count)} ${plural(usage.containers.count, "container", "containers")}, ${exact(stopped.length)} stopped`}
                  reclaim={usage.containers.reclaimable}
                  action={stopped.length > 0 ? "Remove stopped" : null}
                  onAction={() =>
                    setPending({ kind: "prune", prune: "containers", size: usage.containers.reclaimable, items: stopped.map((c) => `${c.name} (${c.image})`), total: stopped.length })
                  }
                />
                <DockerRow
                  title="Build cache"
                  size={usage.build_cache.size}
                  detail="Layers kept to build faster"
                  reclaim={usage.build_cache.reclaimable}
                  action={usage.build_cache.size > 0 ? "Clear" : null}
                  onAction={() => setPending({ kind: "prune", prune: "build_cache", size: usage.build_cache.reclaimable, items: [], total: 0 })}
                />
                <li className="reclaim-group" data-risk="careful">
                  <div className="reclaim-row">
                    <span className="led reclaim-led" data-risk="careful" aria-hidden="true" />
                    <span className="reclaim-title">Volumes</span>
                    <span className="reclaim-size">{bytes(usage.volumes.size)}</span>
                  </div>
                  <p className="reclaim-why">
                    <span className="reclaim-risk">Data, not made again.</span> Databases, uploads, what containers keep: Headroom does not remove
                    them. <code>docker volume rm &lt;name&gt;</code> removes one.
                  </p>
                  {usage.volume_list.length > 0 && (
                    <ul className="reclaim-places">
                      {usage.volume_list.slice(0, 8).map((v) => (
                        <li key={v.name} className="reclaim-place machine-volume">
                          <span className="reclaim-path">
                            {v.name}
                            {v.used ? "" : " (not in use)"}
                          </span>
                          <span className="reclaim-place-size">{bytes(v.size)}</span>
                        </li>
                      ))}
                    </ul>
                  )}
                </li>
              </ul>
            )
          )}
        </section>
      </div>
      {pending && (
        <ConfirmRun
          pending={pending}
          admin={admin}
          busy={busy}
          error={error}
          onConfirm={confirm}
          onAdmin={onAdmin}
          onCancel={() => {
            setPending(null);
            setError(null);
          }}
        />
      )}
    </div>
  );
}

function DockerRow(props: { title: string; size: number; detail: string; reclaim: number; action: string | null; onAction: () => void }) {
  return (
    <li className="reclaim-group machine-docker" data-risk="rebuild">
      <div className="reclaim-row">
        <span className="led reclaim-led" data-risk="rebuild" aria-hidden="true" />
        <span className="reclaim-title">{props.title}</span>
        <span className="reclaim-size">{bytes(props.size)}</span>
      </div>
      <p className="reclaim-why">
        {props.detail}
        {props.reclaim > 0 && <>; {bytes(props.reclaim)} can go</>}
      </p>
      {props.action && (
        <div className="reclaim-actions">
          <button className="control reclaim-do" onClick={props.onAction}>
            {props.action}
          </button>
        </div>
      )}
    </li>
  );
}

function ConfirmRun(props: {
  pending: Pending;
  admin: boolean;
  busy: boolean;
  error: string | null;
  onConfirm: () => void;
  onAdmin: () => void;
  onCancel: () => void;
}) {
  const { pending, admin, busy, error, onConfirm, onAdmin, onCancel } = props;
  const cancel = useRef<HTMLButtonElement>(null);
  useEffect(() => cancel.current?.focus(), []);
  const compacting = pending.kind === "compact";
  const needsAdmin = compacting && !admin;
  const text = compacting ? null : prunes[pending.prune];
  return (
    <div className="veil" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && !busy && onCancel()}>
      <section className="dialog" role="alertdialog" aria-labelledby="run-title" data-mode="permanent">
        <h2 id="run-title" className="dialog-title">
          {compacting ? `Compact ${pending.distro.name}'s disk?` : text!.title}
        </h2>
        <p className="dialog-size">{compacting ? bytes(pending.distro.size) : bytes(pending.size)}</p>
        {!compacting && pending.items.length > 0 && (
          <ul className="dialog-list">
            {pending.items.slice(0, 6).map((item) => (
              <li key={item}>
                <span className="reclaim-path">{item}</span>
              </li>
            ))}
            {pending.total > 6 && <li className="reclaim-rest">and {exact(pending.total - 6)} more</li>}
          </ul>
        )}
        <p className="dialog-note">
          {compacting
            ? "Gives Windows back what was freed inside the distribution. WSL stops first: every distribution, and Docker Desktop with it. It takes minutes for a large disk; nothing inside changes."
            : `${text!.note} (${text!.command})`}
        </p>
        {needsAdmin && <p className="dialog-error">Compacting needs administrator: Headroom can start again as administrator.</p>}
        {error && (
          <p className="dialog-error" role="alert">
            {error}
          </p>
        )}
        <div className="dialog-actions">
          <span className="dialog-switch" />
          <button ref={cancel} className="control" onClick={onCancel} disabled={busy}>
            Cancel
          </button>
          {needsAdmin ? (
            <button className="control control-danger" onClick={onAdmin}>
              Restart as administrator
            </button>
          ) : (
            <button className="control control-danger" onClick={onConfirm} disabled={busy}>
              {busy ? (compacting ? "Compacting…" : "Working…") : compacting ? "Stop WSL and compact" : text!.button}
            </button>
          )}
        </div>
      </section>
    </div>
  );
}
