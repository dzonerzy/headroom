import { useEffect, useRef } from "react";
import { Plume, type Removal } from "./bindings";
import { bytes, exact, plural } from "./format";

export type Mode = "trash" | "permanent";

/** Where things go to be undone, by its system's name. */
export const bin = Plume.platform === "windows" ? "Recycle Bin" : "Trash";

type Props = {
  removal: Removal;
  mode: Mode;
  busy: boolean;
  error: string | null;
  onMode: (mode: Mode) => void;
  onConfirm: () => void;
  onCancel: () => void;
};

/** Asks before anything is deleted: what, how big, where, and when the
 * space comes back; permanently only on a second, red, explicit choice. */
export function ConfirmRemove({ removal, mode, busy, error, onMode, onConfirm, onCancel }: Props) {
  const cancel = useRef<HTMLButtonElement>(null);
  const confirm = useRef<HTMLButtonElement>(null);
  // Permanent: Cancel has the focus, so Enter does not destroy anything.
  useEffect(() => {
    (mode === "permanent" ? cancel : confirm).current?.focus();
  }, [mode]);

  const what = removal.folder
    ? `${exact(removal.files)} ${plural(removal.files, "file", "files")}, ${bytes(removal.size)}`
    : bytes(removal.size);
  return (
    <div className="veil" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && !busy && onCancel()}>
      <section className="dialog" role="alertdialog" aria-labelledby="remove-title" data-mode={mode}>
        <h2 id="remove-title" className="dialog-title">
          {mode === "trash" ? `Move ${removal.name} to the ${bin}?` : `Delete ${removal.name} permanently?`}
        </h2>
        <p className="dialog-size">{what}</p>
        <p className="dialog-path">{removal.path}</p>
        {removal.warning && <p className="dialog-warning">{removal.warning}</p>}
        <p className="dialog-note">
          {mode === "trash"
            ? `You can restore it from the ${bin}. The space comes back when the ${bin} is emptied.`
            : "It does not go to the " + bin + ": this cannot be undone. The space comes back at once."}
        </p>
        {error && <p className="dialog-error" role="alert">{error}</p>}
        <div className="dialog-actions">
          {mode === "trash" ? (
            <button className="control control-quiet dialog-switch" onClick={() => onMode("permanent")} disabled={busy}>
              Delete permanently instead
            </button>
          ) : (
            <span className="dialog-switch" />
          )}
          <button ref={cancel} className="control" onClick={onCancel} disabled={busy}>
            Cancel
          </button>
          <button
            ref={confirm}
            className={mode === "trash" ? "control control-main" : "control control-danger"}
            onClick={onConfirm}
            disabled={busy}
          >
            {busy
              ? mode === "trash"
                ? `Moving to the ${bin}…`
                : "Deleting…"
              : mode === "trash"
                ? `Move to the ${bin}`
                : `Delete ${bytes(removal.size)} permanently`}
          </button>
        </div>
      </section>
    </div>
  );
}
