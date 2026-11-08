// esbuild bundling config - invoked by "npm run build"
// Uses the CLI form documented in package.json scripts.
// This file exists for IDE tooling and potential CI overrides.
export default {
  entryPoints: ["src/index.ts"],
  bundle: true,
  outfile: "dist/index.js",
  platform: "node",
  format: "esm",
  target: "node18",
  sourcemap: true,
  external: ["fs", "path", "crypto", "os", "child_process", "net", "http"],
};
