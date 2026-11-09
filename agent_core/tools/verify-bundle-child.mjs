// tools/verify-bundle-child.mjs - smoke-import a built bundle, assert public symbols.
// (Windows requires a file:// URL for absolute ESM imports.)
import {pathToFileURL} from "node:url";
const entry = process.argv[2];
if (!entry) { console.error("verify-bundle-child: entry path required"); process.exit(2); }
const EXPECTED = ["ReActEngine","ProcessSupervisor","CheckpointStore","buildDefaultToolRegistry"];
const mod = await import(pathToFileURL(entry).href);
const missing = EXPECTED.filter((k) => !(k in mod));
if (missing.length) {
  console.error("missing symbols: " + missing.join(", "));
  process.exit(1);
}
console.log("bundle-ok (" + EXPECTED.length + " symbols present)");
