import { useState } from "react";
import type { DupeCopy, Dupes, Group, Place, DupesProgress } from "./bindings";
import { bytes, bytesParts, exact, plural } from "./format";

/** Duplicates: before a search, the way to start it; during, how far; after,
 * the groups of identical files, the oldest copy of each kept by default. */
export function DupesList(props: {
  dupes: Dupes | null;
  finding: boolean;
  progress: DupesProgress | null;
  busy: string | null;
  onFind: () => void;
  onCancel: () => void;
  onClean: (group: Group) => void;
  onGo: (place: Place) => void;
}) {
  const { dupes, finding, progress, busy, onFind, onCancel, onClean, onGo } = props;
  // The copies to remove: every one but the oldest of each group, at first;
  // set again (while rendering, so never shown unchecked) for new results.
  const [choice, setChoice] = useState(() => ({ of: dupes, chosen: defaults(dupes) }));
  if (choice.of !== dupes) setChoice({ of: dupes, chosen: defaults(dupes) });
  const chosen = choice.of === dupes ? choice.chosen : defaults(dupes);
  const setChosen = (next: Set<number>) => setChoice({ of: dupes, chosen: next });

  if (!dupes) {
    return (
      <div className="side-body">
        <header className="reclaim-head">
          <div>
            <p className="reclaim-caption dupes-intro">
              Files with the same bytes, a megabyte and up: the same video downloaded twice, a backup of a backup. Same-size files are
              compared by their bytes, so it reads them.
            </p>
          </div>
        </header>
        <div className="reclaim-actions stale-all">
          {finding ? (
            <>
              <span className="dupes-progress" role="status">
                {progress ? `Compared ${exact(progress.done)} of ${exact(progress.files)} files, ${bytes(progress.bytes)} read` : "Comparing…"}
              </span>
              <button className="control control-quiet" onClick={onCancel}>
                Stop
              </button>
            </>
          ) : (
            <button className="control reclaim-do dupes-find" onClick={onFind}>
              Find duplicates
            </button>
          )}
        </div>
      </div>
    );
  }

  const removing = dupes.groups.flatMap((g) => g.copies.filter((c) => chosen.has(c.node)).map((c) => ({ copy: c, size: g.size })));
  const freed = removing.reduce((sum, r) => sum + r.size, 0);
  const [value, unit] = bytesParts(dupes.wasted);

  function toggle(groupCopies: DupeCopy[], node: number) {
    const next = new Set(chosen);
    if (next.has(node)) next.delete(node);
    else {
      // One copy of each always stays.
      const others = groupCopies.filter((c) => c.node !== node && !next.has(c.node));
      if (others.length === 0) return;
      next.add(node);
    }
    setChosen(next);
  }

  function removeChosen() {
    const items: Place[] = removing
      .map((r) => ({ node: r.copy.node, path: r.copy.path, size: r.size, parent: r.copy.parent }))
      .sort((a, b) => b.size - a.size);
    onClean({
      id: "dupes",
      title: "duplicate copies",
      why: "Copies of files that stay in one place each.",
      risk: "careful",
      action: "delete",
      command: null,
      size: freed,
      count: items.length,
      items: items.slice(0, 40),
      nodes: items.map((i) => i.node),
    });
  }

  return (
    <div className="side-body">
      <header className="reclaim-head">
        <div>
          <p className="figure reclaim-figure">
            <span className="figure-value">{value}</span>
            <span className="figure-unit">{unit}</span>
          </p>
          <p className="reclaim-caption">
            in {exact(dupes.groups.length)} {plural(dupes.groups.length, "file", "files")} kept more than once; one copy of each stays
          </p>
        </div>
      </header>
      {dupes.groups.length === 0 ? (
        <p className="reclaim-empty">No file of a megabyte or more is here twice.</p>
      ) : (
        <>
          <div className="reclaim-actions stale-all">
            <button className="control reclaim-do" disabled={removing.length === 0 || busy === "dupes"} onClick={removeChosen}>
              {busy === "dupes" ? "Removing…" : `Remove ${exact(removing.length)} ${plural(removing.length, "copy", "copies")} (${bytes(freed)})`}
            </button>
          </div>
          <ul className="reclaim-groups">
            {dupes.groups.map((group) => (
              <li key={group.copies[0].node} className="reclaim-group dupes-group" data-risk="careful">
                <div className="reclaim-row">
                  <span className="led reclaim-led" data-risk="careful" aria-hidden="true" />
                  <span className="reclaim-title" title={group.copies[0].path}>
                    {group.copies[0].name}
                  </span>
                  <span className="reclaim-size">{bytes(group.wasted)}</span>
                </div>
                <p className="reclaim-why">
                  {exact(group.copies.length)} copies of {bytes(group.size)}
                </p>
                <ul className="reclaim-places">
                  {group.copies.map((copy) => (
                    <li key={copy.node} className="dupes-copy">
                      <input
                        type="checkbox"
                        checked={chosen.has(copy.node)}
                        onChange={() => toggle(group.copies, copy.node)}
                        aria-label={`Remove ${copy.path}`}
                      />
                      <button className="reclaim-place" onClick={() => onGo({ node: copy.node, path: copy.path, size: group.size, parent: copy.parent })} title={copy.path}>
                        <span className="reclaim-path">{copy.path}</span>
                        <span className="reclaim-place-size">
                          {chosen.has(copy.node) ? "goes" : "stays"}, from {new Date(copy.mtime * 1000).toLocaleDateString(undefined, { dateStyle: "medium" })}
                        </span>
                      </button>
                    </li>
                  ))}
                </ul>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}

/** Every copy but the oldest of each group. */
function defaults(dupes: Dupes | null): Set<number> {
  const all = new Set<number>();
  for (const group of dupes?.groups ?? []) {
    const keep = oldest(group.copies);
    for (const copy of group.copies) if (copy.node !== keep) all.add(copy.node);
  }
  return all;
}

/** The copy written first: the original, most likely. */
function oldest(copies: DupeCopy[]): number {
  return copies.reduce((a, b) => (b.mtime > 0 && (a.mtime === 0 || b.mtime < a.mtime) ? b : a)).node;
}
