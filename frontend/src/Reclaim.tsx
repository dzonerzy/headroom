import { useEffect, useRef, useState } from "react";
import type { Group, Place, Reclaim } from "./bindings";
import { bytes, bytesParts, exact, plural } from "./format";
import { bin } from "./Remove";

const risks = {
  safe: "Comes back by itself",
  rebuild: "Comes back with a build",
  careful: "Look before clearing",
} as const;

type Props = {
  reclaim: Reclaim;
  busy: string | null;
  onClean: (group: Group) => void;
  onCopy: (command: string) => void;
  onGo: (place: Place) => void;
  onHover: (place: Place | null) => void;
  onClose: () => void;
};

/** What can go: the rules' findings by kind, biggest first, each with what
 * it is, how safe, and the way to clear it. */
export function ReclaimPanel({ reclaim, busy, onClean, onCopy, onGo, onHover, onClose }: Props) {
  const [open, setOpen] = useState<string | null>(null);
  const [value, unit] = bytesParts(reclaim.size);
  return (
    <aside className="reclaim" aria-label="What can go">
      <header className="reclaim-head">
        <div>
          <p className="figure reclaim-figure">
            <span className="figure-value">{value}</span>
            <span className="figure-unit">{unit}</span>
          </p>
          <p className="reclaim-caption">
            can go, and comes back by itself or with a build
            {reclaim.careful > 0 && <>; {bytes(reclaim.careful)} more to look at first</>}
          </p>
        </div>
        <button className="control control-quiet reclaim-close" onClick={onClose} aria-label="Close">
          ✕
        </button>
      </header>

      {reclaim.groups.length === 0 ? (
        <p className="reclaim-empty">Nothing here that Headroom knows how to clear.</p>
      ) : (
        <ul className="reclaim-groups">
          {reclaim.groups.map((group) => (
            <li key={group.id} className="reclaim-group" data-risk={group.risk}>
              <div className="reclaim-row">
                <span className="led reclaim-led" data-risk={group.risk} aria-hidden="true" />
                <span className="reclaim-title">{group.title}</span>
                <span className="reclaim-size">{bytes(group.size)}</span>
              </div>
              <p className="reclaim-why">
                <span className="reclaim-risk">{risks[group.risk]}.</span> {group.why}
              </p>
              <div className="reclaim-actions">
                <Action group={group} busy={busy === group.id} onClean={onClean} onCopy={onCopy} onGo={onGo} />
                <button
                  className="control control-quiet reclaim-more"
                  aria-expanded={open === group.id}
                  onClick={() => setOpen(open === group.id ? null : group.id)}
                >
                  {group.count === 1 ? "Where" : `${exact(group.count)} places`}
                </button>
              </div>
              {open === group.id && (
                <ul className="reclaim-places">
                  {group.items.map((place) => (
                    <li key={place.node}>
                      <button
                        className="reclaim-place"
                        onClick={() => onGo(place)}
                        onMouseEnter={() => onHover(place)}
                        onMouseLeave={() => onHover(null)}
                        title={place.path}
                      >
                        <span className="reclaim-path">{place.path}</span>
                        <span className="reclaim-place-size">{bytes(place.size)}</span>
                      </button>
                    </li>
                  ))}
                  {group.count > group.items.length && (
                    <li className="reclaim-rest">
                      and {exact(group.count - group.items.length)} smaller {plural(group.count - group.items.length, "one", "ones")}
                    </li>
                  )}
                </ul>
              )}
            </li>
          ))}
        </ul>
      )}
    </aside>
  );
}

function Action(props: { group: Group; busy: boolean; onClean: (g: Group) => void; onCopy: (c: string) => void; onGo: (p: Place) => void }) {
  const { group, busy, onClean, onCopy, onGo } = props;
  switch (group.action) {
    case "delete":
      return (
        <button className="control reclaim-do" disabled={busy} onClick={() => onClean(group)}>
          {busy ? "Deleting…" : group.count === 1 ? "Delete it" : `Delete all ${exact(group.count)}`}
        </button>
      );
    case "empty_bin":
      return (
        <button className="control reclaim-do" disabled={busy} onClick={() => onClean(group)}>
          {busy ? "Emptying…" : `Empty the ${bin}`}
        </button>
      );
    case "command":
    case "show":
      return group.command ? (
        <button className="control reclaim-command" onClick={() => onCopy(group.command!)} title="Copy the command">
          <code>{group.command}</code>
          <span className="reclaim-copy">Copy</span>
        </button>
      ) : (
        <button className="control reclaim-do" onClick={() => onGo(group.items[0])}>
          Show it
        </button>
      );
  }
}

type ConfirmProps = {
  group: Group;
  busy: boolean;
  error: string | null;
  onConfirm: (mode: "trash" | "permanent") => void;
  onCancel: () => void;
};

/** Before a group goes: how many, how much, which ones, and how they come
 * back. Caches go for good (the Recycle Bin would keep their space); the
 * Recycle Bin is offered anyway. */
export function ConfirmGroup({ group, busy, error, onConfirm, onCancel }: ConfirmProps) {
  const cancel = useRef<HTMLButtonElement>(null);
  useEffect(() => cancel.current?.focus(), []);
  const emptying = group.action === "empty_bin";
  return (
    <div className="veil" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && !busy && onCancel()}>
      <section className="dialog" role="alertdialog" aria-labelledby="group-title" data-mode="permanent">
        <h2 id="group-title" className="dialog-title">
          {emptying
            ? `Empty the ${bin}?`
            : group.count === 1
              ? `Delete ${group.items[0]?.path ?? group.title}?`
              : `Delete all ${exact(group.count)}: ${group.title}?`}
        </h2>
        <p className="dialog-size">{bytes(group.size)}</p>
        {!emptying && (
          <ul className="dialog-list">
            {group.items.slice(0, 5).map((place) => (
              <li key={place.node}>
                <span className="reclaim-path">{place.path}</span> <span className="dialog-list-size">{bytes(place.size)}</span>
              </li>
            ))}
            {group.count > 5 && <li className="reclaim-rest">and {exact(group.count - 5)} more</li>}
          </ul>
        )}
        <p className="dialog-note">
          {emptying
            ? `What is in the ${bin} cannot be restored after.`
            : `${group.why}${group.command ? ` (${group.command})` : ""} Deleted for good, the space comes back at once; in the ${bin}, only once it is emptied.`}
        </p>
        {error && <p className="dialog-error" role="alert">{error}</p>}
        <div className="dialog-actions">
          {!emptying ? (
            <button className="control control-quiet dialog-switch" onClick={() => onConfirm("trash")} disabled={busy}>
              Move to the {bin} instead
            </button>
          ) : (
            <span className="dialog-switch" />
          )}
          <button ref={cancel} className="control" onClick={onCancel} disabled={busy}>
            Cancel
          </button>
          <button className="control control-danger" onClick={() => onConfirm("permanent")} disabled={busy}>
            {busy ? (emptying ? "Emptying…" : "Deleting…") : emptying ? `Empty the ${bin}` : `Delete ${bytes(group.size)}`}
          </button>
        </div>
      </section>
    </div>
  );
}
