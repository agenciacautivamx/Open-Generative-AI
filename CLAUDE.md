# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Open Generative AI is a multi-model AI image/video/audio/lip-sync/agent studio built on top of the [Muapi.ai](https://muapi.ai) API gateway. It ships as **two separate frontends that share no code** plus a Next.js server that proxies to Muapi:

1. **Hosted/self-hosted web app** — Next.js App Router (`app/`) rendering a React component library (`packages/studio/`).
2. **Desktop app** — Electron (`electron/`) loading a Vite-built vanilla-JS SPA (`src/`), with an extra local-inference engine that only exists in this build.

There is no shared component code between the two frontends — see "The two frontends" below before touching UI.

## Commands

```bash
# First-time setup (REQUIRED before either dev server works)
git submodule update --init --recursive   # populates packages/Vibe-Workflow, Open-Poe-AI, Open-AI-Design-Agent
npm install
npm run build:packages                     # builds workflow-builder, ai-agent, then studio (order matters)
# or just: npm run setup   (does all of the above)

# Hosted web app (Next.js) — http://localhost:3000
npm run dev
npm run build && npm run start             # production build

# Desktop app (Electron + Vite)
npm run electron:dev                       # vite build (src/ → dist/) then launches electron .
npm run electron:build                     # mac DMG
npm run electron:build:win                 # Windows NSIS
npm run electron:build:linux               # Linux AppImage + deb
npm run electron:build:all

# Lint (Next.js/ESLint, covers app/, components/, packages/studio)
npm run lint

# Tests — plain Node test runner, no script defined in package.json
node --test tests/*.test.js
# single file:
node --test tests/localInferencePaths.test.js
```

Notes:
- `npm run setup` runs `git submodule update --init --recursive` then `npm install` then `npm run build:packages`. Skipping this leaves `packages/Vibe-Workflow`, `packages/Open-Poe-AI`, and `packages/Open-AI-Design-Agent` as empty directories — `npm run dev` will fail to resolve the `workflow-builder`, `ai-agent`, and `design-agent` workspace imports (see `jsconfig.json` path aliases) until submodules are populated and `packages/studio` is rebuilt.
- `npm run build:packages` must run `build:workflow` and `build:agent` *before* `build:studio`, because `packages/studio` depends on `workflow-builder`/`ai-agent`/`design-agent` as file: dependencies.
- The desktop app and the web app are independent processes with independent dependency builds — `electron:dev` never touches `packages/studio` or the Next.js server; `npm run dev` never touches `src/` or Vite.
- Tests live only under `tests/` and use Node's built-in `node:test` + `node:assert/strict` (no Jest/Mocha/Vitest installed). They cover `electron/lib/*` (local inference path resolution, asset selection, progress parsing, Wan2GP model-availability filtering) via plain `require()`, no DOM/browser needed.

## Architecture

### The two frontends (read this before any UI change)

| | Web app | Desktop app |
|---|---|---|
| Entry | `app/` (Next.js App Router) | `src/main.js` (Vite, vanilla JS, hand-rolled router) |
| UI components | `packages/studio/src/components/*.jsx` (React) | `src/components/*.js` (vanilla DOM, no framework) |
| API client | `packages/studio/src/muapi.js` | `src/lib/muapi.js` |
| Model catalog | `packages/studio/src/models.js` | `src/lib/models.js` |
| Rendered via | `components/StandaloneShell.js` → `<ImageStudio>` etc. imported from the `studio` workspace package | `electron/main.js` loads `dist/index.html` (Vite build output of `src/`) |
| Local model inference (sd.cpp, Wan2GP) | **Not available** — no Electron IPC bridge in a browser | Available via `window.localAI` (exposed by `electron/preload.js`, backed by `electron/lib/localInference*.js` and `wan2gpProvider.js`) |

These two component trees were forked from each other and have since diverged (e.g. `packages/studio`'s `ImageStudio.jsx` has multi-image-edit / effects support that `src/components/ImageStudio.js` doesn't, and only `src/` has local-inference UI). **A feature or bug fix in "Image/Video/Cinema/LipSync/Workflow Studio" usually needs to be applied in both trees** unless it's specifically about local inference (desktop-only) or something only reachable from the Next.js server (web-only). Check both `packages/studio/src/components/<Name>.jsx` and `src/components/<Name>.js` before assuming a fix is complete.

`packages/studio` is also consumed directly by the hosted production site (muapi.ai/open-generative-ai), so changes to `packages/studio/src/models.js` propagate there as well as to the self-hosted Next.js app.

### Model catalog (`packages/studio/src/models.js` / `src/lib/models.js`)

Single source of truth for all 200+ models, ~10k lines, partially auto-generated from `models_dump.json` (see the file header comment). Structured as flat arrays per category with `getXById` lookup helpers:

- `t2iModels` / `i2iModels` — text-to-image / image-to-image
- `t2vModels` / `i2vModels` / `v2vModels` — text-to-video / image-to-video / video-to-video
- `lipsyncModels` (filtered into `imageLipSyncModels` / `videoLipSyncModels` via `category`)
- `audioModels`

Each model entry has `id`, `name`, an `endpoint` (maps to the Muapi API path — **not always equal to `id`**, e.g. `flux-dev` → `flux-dev-image`), and an `inputs` schema (JSON-schema-ish: `type`, `enum`/`minValue`/`maxValue`/`step`, `default`) that the studio components introspect to decide which controls to render (aspect ratio picker, resolution/quality picker, duration, max reference images, etc). Adding a model means adding an entry here, not writing new UI — the studios read capabilities off `inputs` and the various `getXForModel` helpers.

### API integration: submit → poll, and where requests actually go

Both `muapi.js` clients follow the same two-step pattern: `POST /api/v1/{endpoint}` returns a `request_id`, then poll `GET /api/v1/predictions/{request_id}/result` until `status` is `completed`/`succeeded`/`failed`. Auth is the `x-api-key` header (never `Authorization: Bearer` toward Muapi itself).

Where the request actually lands differs by runtime, decided in `packages/studio/src/muapi.js`:
```js
BASE_URL = (window exists && protocol starts with http) ? '/api' : 'https://api.muapi.ai'
```
- In the **browser over http(s)** (Next.js dev/prod), requests go to local `/api/*` Next.js route handlers (`app/api/**/route.js`), which strip the cookie, attach `x-api-key` from either the `x-api-key` header or the `muapi_key` cookie, and `fetch()` straight through to `https://api.muapi.ai` server-side — this is what avoids CORS.
- In **Electron's `file://` renderer** or during **SSR**, there's no `http` origin, so the client calls `https://api.muapi.ai` directly.
- The Vite dev server additionally proxies `/api` → `https://api.muapi.ai` (`vite.config.mjs`) for the desktop app's dev loop.

`middleware.js` is a second, broader proxy layer for `/api/workflow`, `/api/app`, `/api/v1/*` (rewrites straight to `api.muapi.ai`) except for three paths that have dedicated route handlers with custom logic (`creative-agent`, `get_upload_url`, `upload-binary`) — check `app/api/**/route.js` before assuming `middleware.js` owns a given `/api/v1/...` path.

File uploads: `POST /api/v1/upload_file` (multipart) returns a hosted URL; for multi-image models the full `images_list` array is sent in one request instead of one `image_url`.

Auth identity for SSR pages (e.g. `app/agents/[agent_id]/page.js`, `app/workflow/[id]/page.js`) comes from the `muapi_key` cookie (set client-side in `StandaloneShell.js` whenever the API key changes), not from `localStorage` — server components can't read `localStorage`.

### Local inference (desktop app only, `electron/lib/`)

Two independent engines, both driven from the main process and exposed to `src/` via `electron/preload.js`'s `window.localAI` bridge:
- **sd.cpp** (`localInference.js`, `localInferenceAssets.js`, `localInferencePaths.js`, `localInferenceRuntime.js`) — downloads a prebuilt `sd-cli` binary + model weights into the Electron user-data dir (overridable via `OPEN_GENERATIVE_AI_LOCAL_AI_DIR`), spawns it as a child process, parses stdout for progress.
- **Wan2GP** (`wan2gpProvider.js`, `wan2gpModelAvailability.js`) — HTTP client to a user-run remote Gradio server; no bundled binary, just probes/calls a URL the user supplies in Settings.

`src/lib/localInferenceClient.js` and `src/lib/localModels.js` are the renderer-side counterparts consumed only by `src/components/*`.

### Workspaces and submodules

`package.json` declares npm workspaces: `packages/studio`, plus three git submodules under `packages/`: `Vibe-Workflow` (workflow-builder), `Open-Poe-AI` (ai-agent), `Open-AI-Design-Agent` (design-agent). These are separate GitHub repos vendored in-tree — don't expect their source to be present without `git submodule update --init --recursive`. `next.config.mjs`'s `transpilePackages` and `jsconfig.json`'s path aliases both list `studio`/`ai-agent`/`workflow-builder`/`design-agent` — if you add a new cross-package import, both may need updating. The Dockerfile clones these submodules directly from GitHub in a separate stage (Railway doesn't clone submodules), so don't assume CI/deploy environments share the local `.gitmodules` checkout state.

### Standalone SSR routes vs. the embedded studio tabs

`components/StandaloneShell.js` (rendered at `app/studio/[[...slug]]/page.js`) is the tabbed SPA shell most users hit — it client-side-renders all the `*Studio` components from the `studio` package based on the URL slug. Separately, `app/agents/[agent_id]/...` and `app/workflow/[id]/...` are dedicated server-rendered routes for *sharable* deep links into a single agent chat or workflow run; they fetch directly from `https://api.muapi.ai` server-side using the `muapi_key` cookie rather than going through the SPA shell. Don't assume agent/workflow logic only lives in one place.
