import { useEffect, useId, useMemo, useState, type KeyboardEvent } from "react";
import { App, type Found, type View } from "./bindings";
import { bytes, exact, plural, share } from "./format";

/** Finding by name: the scanned tree's entries whose name holds what is
 * typed, the biggest first; one picked goes to the map. */
export function Search({ onPick }: { onPick: (found: Found) => void }) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Found[]>([]);
  const [active, setActive] = useState(0);
  const [open, setOpen] = useState(false);
  const list = useId();

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setResults(query.trim().length >= 2 ? App.search(query) : []);
      setActive(0);
    }, 180);
    return () => window.clearTimeout(timer);
  }, [query]);

  function pick(found: Found) {
    onPick(found);
    setOpen(false);
  }

  function key(event: KeyboardEvent) {
    if (event.key === "ArrowDown") setActive((a) => Math.min(a + 1, results.length - 1));
    else if (event.key === "ArrowUp") setActive((a) => Math.max(a - 1, 0));
    else if (event.key === "Enter" && results[active]) pick(results[active]);
    else if (event.key === "Escape") {
      setQuery("");
      setOpen(false);
    } else return;
    event.preventDefault();
  }

  const shown = open && query.trim().length >= 2;
  return (
    <div className="search">
      <input
        className="search-field"
        type="search"
        placeholder="Find by name"
        aria-label="Find by name"
        role="combobox"
        aria-expanded={shown}
        aria-controls={list}
        aria-activedescendant={shown && results[active] ? `${list}-${active}` : undefined}
        value={query}
        onChange={(event) => {
          setQuery(event.target.value);
          setOpen(true);
        }}
        onFocus={() => setOpen(true)}
        onBlur={() => window.setTimeout(() => setOpen(false), 150)}
        onKeyDown={key}
      />
      {shown && (
        <ul className="search-results" id={list} role="listbox">
          {results.length === 0 ? (
            <li className="search-none">Nothing named like that.</li>
          ) : (
            results.map((found, i) => (
              <li
                key={found.node}
                id={`${list}-${i}`}
                role="option"
                aria-selected={i === active}
                className="search-result"
                onMouseDown={(event) => {
                  event.preventDefault();
                  pick(found);
                }}
                onMouseEnter={() => setActive(i)}
              >
                <span className="search-name">{found.name}</span>
                <span className="search-size">{bytes(found.size)}</span>
                <span className="search-path">{found.path}</span>
              </li>
            ))
          )}
        </ul>
      )}
    </div>
  );
}

/** The folder on the map as a list: what it holds, the biggest first, each
 * a button (folders open), its share drawn. For the keyboard and screen
 * readers, and for reading long names. */
export function ListView({ view, onOpen, onHover }: { view: View; onOpen: (node: number) => void; onHover: (node: number | null) => void }) {
  const entries = useMemo(() => App.entries(view.node), [view]);
  const biggest = entries[0]?.size ?? 1;
  return (
    <div className="listing" role="region" aria-label={`What ${view.crumbs[view.crumbs.length - 1]?.name ?? "this folder"} holds`}>
      <ul className="listing-rows">
        {entries.map((entry) => (
          <li key={entry.node}>
            <button
              className="listing-row"
              data-opens={entry.opens ? "" : undefined}
              onClick={() => entry.opens && onOpen(entry.node)}
              onMouseEnter={() => onHover(entry.node)}
              onMouseLeave={() => onHover(null)}
              onFocus={() => onHover(entry.node)}
              aria-label={`${entry.name}, ${bytes(entry.size)}, ${share(entry.size / Math.max(view.size, 1))} of this folder${entry.opens ? ", opens" : ""}`}
            >
              <span className="listing-mark" style={entry.color ? { background: entry.color } : undefined} data-folder={entry.kind === "folder" ? "" : undefined} aria-hidden="true" />
              <span className="listing-name">{entry.name}</span>
              <span className="listing-files">
                {entry.kind === "folder" ? `${exact(entry.files)} ${plural(entry.files, "file", "files")}` : ""}
              </span>
              <span className="listing-size">{bytes(entry.size)}</span>
              <span className="listing-track" aria-hidden="true">
                <span className="listing-bar" style={{ width: `${Math.max(0.5, (entry.size / biggest) * 100)}%` }} />
              </span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
