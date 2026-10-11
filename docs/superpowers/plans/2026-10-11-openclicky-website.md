# openclicky.flowsxr.com Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A one-page site at openclicky.flowsxr.com whose hero shows, inside ten seconds, a pointer flying out of a laptop's notch and marking the answer on screen.

**Architecture:** A new public repo `prasanthsasikumar/openclicky-site` of plain HTML, CSS and one ES module (`assets/demo.js`) with no build step, deployed by Netlify from `main` with deploy previews per pull request. The demo's maths (easing, arc, mark geometry) are pure exported functions unit-tested with `node --test`; the page behaviour (reduced motion, phones, play-when-visible, links) is tested with Playwright against a local static server.

**Tech Stack:** HTML, CSS, JavaScript (ES2022 module), Node 20+ `node:test`, `@playwright/test` (dev only), `netlify-cli` (logged in on this Mac, personal account, manages the flowsxr.com DNS zone), `gh` (logged in as prasanthsasikumar).

**Spec:** `docs/superpowers/specs/2026-10-11-openclicky-website-design.md` (in the openclicky repo)

## Global Constraints

- Site repo: `~/Documents/GitHub/openclicky-site`, public, MIT, remote `prasanthsasikumar/openclicky-site`.
- No framework, no build step, no runtime npm dependencies. Dev dependencies only for tests.
- Palette: paper `#F4F1EA`, ink `#22201C`, ink-2 `#5E5A52`, ink-3 `#736E64`, pointer `#F0452B`. System font stack, no web fonts.
- Pointer orange is never used for small body text on paper (contrast); only the large headline line and graphics.
- Every Download button links to `/download`; `/download` 302-redirects to `https://github.com/prasanthsasikumar/openclicky/releases/latest`.
- Discord buttons and links are absent from the page until the invite exists; then `/discord` 302-redirects to it.
- HTML + CSS + JS under 60 KB gzipped; first screen under 300 KB; clips `preload="none"`, lazy, under 1 MB each.
- Headline copy, verbatim: "Ask your Mac." / "It shows you where."
- Hero line, verbatim: "Hold ⌃⌥ and ask out loud. A pointer flies out of the notch and marks the answer on your screen. Hold fn and talk, and it types for you. Free and open source."
- Requirements line, verbatim: "macOS 14.2 or later · Apple Silicon and Intel · notarized"
- `openclicky.flowsxr.com` is attached to the Netlify site only after an OpenClicky release draws the mark (Task 9 is gated on that).

## Review Focus

- A visitor with Reduce Motion on must see the still frame (Battery Health marked, "here it is!") and nothing moving — Task 4 Playwright test.
- A visitor who scrolls away mid-flight and back must see the demo restart cleanly, never a pointer frozen mid-arc or two marks stacked — Task 4 test (`restarts clean after leaving view`).
- A phone visitor (390 px) must get no horizontal scrolling and a "Download for Mac" button with "Open this page on your Mac to install." — Task 6 test.
- The GitHub API being down or rate-limited must leave the open-source section intact with no "undefined" or "NaN" — Task 5 test.
- A visitor whose window is resized while the demo runs must see the pointer land on the target, not where it used to be — Task 4 (positions are measured at the start of every flight, never cached) and its resize test.

---

### Task 1: Repository, page skeleton, test harness, Netlify config

**Files:**
- Create: `~/Documents/GitHub/openclicky-site/index.html`
- Create: `assets/site.css`
- Create: `netlify.toml`
- Create: `package.json`, `playwright.config.mjs`, `.gitignore`, `LICENSE`, `README.md`
- Test: `tests/page.spec.mjs`

**Interfaces:**
- Produces: `index.html` with sections `#hero`, `#what`, `#private`, `#open-source`, `#try`, `footer`; CSS custom properties `--paper --ink --ink-2 --ink-3 --pointer`; `npm test` (unit + page), `npm run serve` on port 4173.

- [ ] **Step 1: Create the repo folder and git**

```bash
mkdir -p ~/Documents/GitHub/openclicky-site/{assets/media,tests/unit}
cd ~/Documents/GitHub/openclicky-site
git init -b main
```

- [ ] **Step 2: package.json, Playwright config, .gitignore**

`package.json`:
```json
{
  "name": "openclicky-site",
  "private": true,
  "type": "module",
  "scripts": {
    "serve": "python3 -m http.server 4173 --bind 127.0.0.1",
    "test:unit": "node --test tests/unit/",
    "test:page": "playwright test",
    "test": "npm run test:unit && npm run test:page"
  },
  "devDependencies": {
    "@playwright/test": "^1.48.0"
  }
}
```

`playwright.config.mjs`:
```js
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "tests",
  testMatch: "*.spec.mjs",
  use: { baseURL: "http://127.0.0.1:4173" },
  webServer: { command: "npm run serve", url: "http://127.0.0.1:4173", reuseExistingServer: true },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
    { name: "webkit", use: { ...devices["Desktop Safari"] } },
  ],
});
```

`.gitignore`:
```
node_modules/
test-results/
playwright-report/
.netlify/
```

Run: `npm install && npx playwright install chromium webkit`

- [ ] **Step 3: Write the failing page test**

`tests/page.spec.mjs`:
```js
import { test, expect } from "@playwright/test";

test("page loads without console errors and every Download goes to /download", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("console", (message) => { if (message.type() === "error") errors.push(message.text()); });
  await page.goto("/");
  await expect(page).toHaveTitle("OpenClicky: ask your Mac, it shows you where");
  await expect(page.locator("h1")).toContainText("Ask your Mac.");
  await expect(page.locator("h1")).toContainText("It shows you where.");
  const downloadLinks = page.getByRole("link", { name: /Download for (macOS|Mac)/ });
  expect(await downloadLinks.count()).toBeGreaterThanOrEqual(2);
  for (const link of await downloadLinks.all()) await expect(link).toHaveAttribute("href", "/download");
  for (const id of ["hero", "what", "private", "open-source", "try"]) await expect(page.locator(`#${id}`)).toHaveCount(1);
  await expect(page.locator("footer")).toHaveCount(1);
  expect(errors).toEqual([]);
});

test("no Discord link while the invite does not exist", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator('a[href="/discord"]')).toHaveCount(0);
});
```

Run: `npx playwright test tests/page.spec.mjs --project=chromium`
Expected: FAIL (no index.html, 404 title).

- [ ] **Step 4: Write index.html**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OpenClicky: ask your Mac, it shows you where</title>
  <meta name="description" content="Hold ⌃⌥ and ask out loud. A pointer flies out of the notch and marks the answer on your screen. Hold fn and talk, and it types for you. Free and open source for macOS.">
  <link rel="icon" href="/assets/mark.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/assets/site.css">
  <script type="module" src="/assets/demo.js"></script>
</head>
<body>
  <header class="site-nav">
    <a class="brand" href="/" aria-label="OpenClicky home">
      <svg class="brand-mark" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3h9v9a9 9 0 1 1-9-9z" fill="none" stroke="currentColor" stroke-width="2.4"/><path d="M10 9l7 3.5-3.4 1-1.6 3.5z" fill="currentColor"/></svg>
      openclicky
    </a>
    <nav class="nav-links">
      <a href="#what">How it works</a>
      <a href="https://github.com/prasanthsasikumar/openclicky">GitHub</a>
    </nav>
  </header>

  <main>
    <section id="hero" class="hero">
      <h1>Ask your Mac.<br><em>It shows you where.</em></h1>
      <p class="lede">Hold ⌃⌥ and ask out loud. A pointer flies out of the notch and marks the answer on your screen. Hold fn and talk, and it types for you. Free and open source.</p>
      <div class="ctas">
        <a class="btn btn-primary" href="/download"><span class="label-wide">Download for macOS</span><span class="label-narrow">Download for Mac</span></a>
      </div>
      <p class="requirements">macOS 14.2 or later · Apple Silicon and Intel · notarized</p>
      <p class="phone-note">Open this page on your Mac to install.</p>
      <!-- the laptop demo goes here (Task 3) -->
    </section>

    <section id="what" class="section"><h2>What it does</h2><!-- Task 5 --></section>
    <section id="private" class="section"><h2>Private by default</h2><!-- Task 5 --></section>
    <section id="open-source" class="section"><h2>Open source</h2><!-- Task 5 --></section>
    <section id="try" class="section">
      <h2>Try it on this page</h2>
      <a class="btn btn-primary" href="/download"><span class="label-wide">Download for macOS</span><span class="label-narrow">Download for Mac</span></a>
    </section>
  </main>

  <footer class="site-footer">
    <a href="https://github.com/prasanthsasikumar/openclicky">GitHub</a>
    <a href="https://github.com/prasanthsasikumar/openclicky/releases">Releases</a>
    <a href="https://github.com/prasanthsasikumar/openclicky#privacy">Privacy</a>
    <a href="https://flowsxr.com">Made by FlowsXR</a>
  </footer>
</body>
</html>
```

(The `<!-- Task N -->` comments are filled by those tasks and removed there. `assets/demo.js` is created empty here: `touch assets/demo.js`. `assets/mark.svg` is the same two paths as the nav mark in a standalone `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">` with `stroke="#22201C"` / `fill="#22201C"`.)

- [ ] **Step 5: Write the base CSS**

`assets/site.css`:
```css
:root {
  --paper: #F4F1EA; --paper-deep: #ECE7DC; --ink: #22201C; --ink-2: #5E5A52; --ink-3: #736E64;
  --pointer: #F0452B;
  --font: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, "Segoe UI", sans-serif;
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
@media (prefers-reduced-motion: reduce) { html { scroll-behavior: auto; } }
body { margin: 0; background: var(--paper); color: var(--ink); font: 16px/1.55 var(--font); -webkit-font-smoothing: antialiased; }
a { color: inherit; }
.site-nav { display: flex; align-items: center; justify-content: space-between; padding: 20px clamp(20px, 4vw, 40px); max-width: 1200px; margin: 0 auto; }
.brand { display: flex; align-items: center; gap: 8px; font-weight: 700; letter-spacing: -.01em; text-decoration: none; }
.brand-mark { width: 22px; height: 22px; }
.nav-links { display: flex; gap: 22px; font-size: 15px; color: var(--ink-2); }
.nav-links a { text-decoration: none; }
.nav-links a:hover { color: var(--ink); }
.hero { text-align: center; padding: 24px 20px 0; max-width: 1200px; margin: 0 auto; }
h1 { font-size: clamp(34px, 6vw, 60px); line-height: 1.04; letter-spacing: -.03em; margin: 0 0 14px; font-weight: 750; }
h1 em { font-style: normal; color: var(--pointer); }
.lede { margin: 0 auto 22px; color: var(--ink-2); max-width: 580px; font-size: clamp(16px, 1.6vw, 18px); }
.ctas { display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; }
.btn { display: inline-flex; align-items: center; gap: 8px; border-radius: 999px; padding: 12px 22px; font-weight: 600; font-size: 15px; text-decoration: none; }
.btn-primary { background: var(--ink); color: var(--paper); }
.btn-primary:hover { background: #000; }
.btn-ghost { box-shadow: inset 0 0 0 1.5px rgba(34, 32, 28, .25); }
.btn:focus-visible, a:focus-visible { outline: 3px solid var(--pointer); outline-offset: 3px; }
.label-narrow, .phone-note { display: none; }
.requirements { color: var(--ink-3); font-size: 13px; margin: 14px 0 0; }
.section { max-width: 1080px; margin: 0 auto; padding: 96px 20px 0; }
.section h2 { font-size: clamp(26px, 3.4vw, 36px); letter-spacing: -.02em; margin: 0 0 24px; }
.site-footer { display: flex; gap: 24px; justify-content: center; flex-wrap: wrap; padding: 96px 20px 48px; color: var(--ink-2); font-size: 14px; }
.visually-hidden { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
```

- [ ] **Step 6: netlify.toml, LICENSE, README**

`netlify.toml`:
```toml
[build]
  publish = "."
  command = ""

[[redirects]]
  from = "/download"
  to = "https://github.com/prasanthsasikumar/openclicky/releases/latest"
  status = 302

[[headers]]
  for = "/*"
  [headers.values]
    Content-Security-Policy = "default-src 'self'; img-src 'self' data:; media-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self' https://api.github.com; frame-ancestors 'none'; base-uri 'self'"
    Referrer-Policy = "strict-origin-when-cross-origin"
    X-Content-Type-Options = "nosniff"
    Permissions-Policy = "camera=(), microphone=(), geolocation=()"
    Cache-Control = "public, max-age=300"

[[headers]]
  for = "/assets/*"
  [headers.values]
    Cache-Control = "public, max-age=86400"
```

(Assets get a one-day cache rather than immutable because file names do not carry a hash; that keeps the no-build-step rule.)

`LICENSE`: the MIT text with `Copyright (c) 2026 Prasanth Sasikumar` (copy from `~/Documents/GitHub/openclicky/LICENSE`).

`README.md`:
```markdown
# openclicky-site

The website at https://openclicky.flowsxr.com for [OpenClicky](https://github.com/prasanthsasikumar/openclicky).
Plain HTML, CSS and one ES module; no build step. Netlify deploys `main`; pull requests get previews.

    npm install && npx playwright install chromium webkit
    npm run serve      # http://127.0.0.1:4173
    npm test           # unit tests for the demo maths, then Playwright page tests

Design: `docs/superpowers/specs/2026-10-11-openclicky-website-design.md` in the OpenClicky repo.
```

- [ ] **Step 7: Run the tests**

Run: `touch assets/demo.js && npx playwright test tests/page.spec.mjs`
Expected: PASS on chromium and webkit (2 tests × 2 browsers).

- [ ] **Step 8: Commit and create the GitHub repo**

```bash
git add -A
git commit -m "Page skeleton, test harness and Netlify config for openclicky.flowsxr.com"
gh repo create prasanthsasikumar/openclicky-site --public --source . --push --description "The website for OpenClicky"
```

---

### Task 2: The demo's maths, unit-tested

**Files:**
- Create: `assets/demo.js` (the pure part; Task 3 adds the browser part to the same file)
- Test: `tests/unit/demo-math.test.mjs`

**Interfaces:**
- Produces (exported from `assets/demo.js`):
  - `easeInOutQuad(progress: number) → number` (0→0, 0.5→0.5, 1→1, clamps outside 0…1)
  - `arcPoint(from: {x,y}, to: {x,y}, eased: number, lift = 90) → {x, y}` quadratic bezier whose control point sits `lift` px above the higher endpoint, midway
  - `flightScale(eased: number) → number` `1 + sin(π·eased) · 0.7`
  - `markGeometry(box: {x,y,width,height}, padding = 4) → {left, top, width, height, corners: [{x,y}×4]}` corners clockwise from top-left, in the mark's own coordinates, inset 1 px for the stroke
- The module must not touch `document` or `window` at import time (it is imported by Node).

- [ ] **Step 1: Write the failing tests**

`tests/unit/demo-math.test.mjs`:
```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { easeInOutQuad, arcPoint, flightScale, markGeometry } from "../../assets/demo.js";

test("easing starts at 0, passes 0.5 at the middle, ends at 1, and clamps", () => {
  assert.equal(easeInOutQuad(0), 0);
  assert.equal(easeInOutQuad(0.5), 0.5);
  assert.equal(easeInOutQuad(1), 1);
  assert.equal(easeInOutQuad(-1), 0);
  assert.equal(easeInOutQuad(2), 1);
  assert.ok(easeInOutQuad(0.25) < 0.25, "slow start");
});

test("the arc starts and ends on its endpoints and lifts above both in between", () => {
  const from = { x: 400, y: 10 }, to = { x: 120, y: 300 };
  assert.deepEqual(arcPoint(from, to, 0), from);
  assert.deepEqual(arcPoint(from, to, 1), to);
  const middle = arcPoint(from, to, 0.5);
  assert.ok(middle.y < (from.y + to.y) / 2, "the arc bows upward");
});

test("the pointer grows mid-flight and is normal size at both ends", () => {
  assert.equal(flightScale(0), 1);
  assert.ok(Math.abs(flightScale(1) - 1) < 1e-9);
  assert.ok(Math.abs(flightScale(0.5) - 1.7) < 1e-9);
});

test("the mark surrounds the target with padding and has four corners clockwise", () => {
  const geometry = markGeometry({ x: 100, y: 50, width: 80, height: 20 }, 4);
  assert.deepEqual([geometry.left, geometry.top, geometry.width, geometry.height], [96, 46, 88, 28]);
  assert.deepEqual(geometry.corners, [{ x: 1, y: 1 }, { x: 87, y: 1 }, { x: 87, y: 27 }, { x: 1, y: 27 }]);
});
```

- [ ] **Step 2: Run to see it fail**

Run: `npm run test:unit`
Expected: FAIL, "does not provide an export named 'easeInOutQuad'".

- [ ] **Step 3: Implement**

`assets/demo.js`:
```js
// The demo's maths. Pure functions, no DOM: unit-tested under Node.

export function easeInOutQuad(progress) {
  const clampedProgress = Math.min(1, Math.max(0, progress));
  return clampedProgress < 0.5
    ? 2 * clampedProgress * clampedProgress
    : 1 - Math.pow(-2 * clampedProgress + 2, 2) / 2;
}

// The app flies its pointer along a quadratic bezier whose control point is lifted above the
// higher endpoint, so the flight bows upward like a thrown object (OverlayWindow.animateBezierFlightArc).
export function arcPoint(from, to, eased, lift = 90) {
  const controlX = (from.x + to.x) / 2;
  const controlY = Math.min(from.y, to.y) - lift;
  const inverse = 1 - eased;
  return {
    x: inverse * inverse * from.x + 2 * inverse * eased * controlX + eased * eased * to.x,
    y: inverse * inverse * from.y + 2 * inverse * eased * controlY + eased * eased * to.y,
  };
}

export function flightScale(eased) {
  return 1 + Math.sin(Math.PI * eased) * 0.7;
}

export function markGeometry(box, padding = 4) {
  const width = box.width + padding * 2;
  const height = box.height + padding * 2;
  return {
    left: box.x - padding,
    top: box.y - padding,
    width,
    height,
    corners: [
      { x: 1, y: 1 },
      { x: width - 1, y: 1 },
      { x: width - 1, y: height - 1 },
      { x: 1, y: height - 1 },
    ],
  };
}
```

- [ ] **Step 4: Run to see it pass**

Run: `npm run test:unit`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add assets/demo.js tests/unit/demo-math.test.mjs
git commit -m "The demo's flight arc, easing and mark geometry, unit-tested"
```

---

### Task 3: The laptop and its demo loop

**Files:**
- Modify: `index.html` (replace `<!-- the laptop demo goes here (Task 3) -->`)
- Modify: `assets/site.css` (append)
- Modify: `assets/demo.js` (append the browser part)
- Test: `tests/page.spec.mjs` (append)

**Interfaces:**
- Consumes: `easeInOutQuad`, `arcPoint`, `flightScale`, `markGeometry` from Task 2.
- Produces:
  - `createCancellation() → { cancelled: boolean, cancel(): void }`
  - `sleep(milliseconds, cancellation) → Promise<void>` rejects with `DemoCancelled` once cancelled
  - `flyPointer(pointer, from, to, durationMilliseconds, cancellation) → Promise<void>`
  - `drawMark(container, targetElement, cancellation) → Promise<SVGElement>`
  - `runLaptopDemo(screen, onBeat, cancellation) → Promise<never>` loops until cancelled
  - `resetLaptop(screen)` puts every element back to the start state
  - `showStillFrame(screen)` the reduced-motion / no-JS frame
  - DOM contract: `.screen[data-demo="laptop"]` containing `.island`, `.island .said`, `.island .keys`, `[data-pane="wifi"]`, `[data-pane="battery"]`, `[data-target="battery"]`, `[data-target="health"]`, `.compose`, `.compose .typed`, `.orb`, `.orb-text`, `.pointer`, `.bubble`, `.menubar .app-name`; `#demo-caption`.
  - `data-beat` attribute on the screen set to `ask | point | type | rest`, and `data-state="still"` for the still frame (Task 4 and the tests read these).

- [ ] **Step 1: Write the failing test**

Append to `tests/page.spec.mjs`:
```js
test("the laptop demo plays ask → point → type and marks Battery", async ({ page }) => {
  await page.goto("/");
  const screen = page.locator('.screen[data-demo="laptop"]');
  await expect(screen).toHaveAttribute("data-beat", "ask", { timeout: 5000 });
  await expect(page.locator(".island .said")).toHaveText("where do I check battery health?", { timeout: 5000 });
  await expect(screen).toHaveAttribute("data-beat", "point", { timeout: 5000 });
  await expect(screen.locator(".mark.filled")).toHaveCount(1, { timeout: 5000 });
  await expect(screen.locator(".bubble")).toHaveText("click this!");
  await expect(screen).toHaveAttribute("data-beat", "type", { timeout: 12000 });
  await expect(screen.locator(".compose .typed")).toContainText("Battery health says normal", { timeout: 8000 });
});
```

Run: `npx playwright test -g "laptop demo" --project=chromium`
Expected: FAIL, no `.screen[data-demo="laptop"]`.

- [ ] **Step 2: The laptop markup**

Replace the Task 3 comment in `index.html` with:
```html
<div class="stage">
  <p class="visually-hidden">Demonstration: on a MacBook, someone asks out loud "where do I check battery health?". A pointer flies out of the notch to Battery in System Settings and marks it, then to Battery Health. Then they hold fn and speak, and a message is typed for them.</p>
  <div class="laptop" aria-hidden="true">
    <div class="lid">
      <div class="screen" data-demo="laptop" data-state="still">
        <div class="menubar"><span class="apple"></span><b class="app-name">System Settings</b><span>File</span><span>Edit</span><span>View</span><span>Window</span><span class="menubar-right">100%&nbsp;&nbsp;Sat 9:41</span></div>
        <div class="island"><div class="island-content"><div class="wave"><i></i><i></i><i></i><i></i><i></i></div><span class="said"></span><span class="keys">⌃ ⌥ held</span></div></div>
        <div class="win">
          <div class="lights"><i></i><i></i><i></i></div>
          <div class="side">
            <div><span class="dot dot-blue"></span>Wi-Fi</div>
            <div><span class="dot dot-blue"></span>Bluetooth</div>
            <div><span class="dot dot-blue"></span>Network</div>
            <div><span class="dot dot-red"></span>Notifications</div>
            <div><span class="dot dot-purple"></span>Sound</div>
            <div data-target="battery"><span class="dot dot-green"></span>Battery</div>
            <div><span class="dot dot-grey"></span>General</div>
            <div><span class="dot dot-grey"></span>Displays</div>
          </div>
          <div class="main">
            <div class="pane" data-pane="wifi"><h4>Wi-Fi</h4><div class="row">Wi-Fi <span>On</span></div><div class="row">Home network <span>Connected</span></div><div class="row">Ask to join networks <span>Off</span></div></div>
            <div class="pane" data-pane="battery"><h4>Battery</h4><div class="row">Low Power Mode <span>Never</span></div><div class="row" data-target="health">Battery Health <span>Normal ⓘ</span></div><div class="row">Charging <span>Optimised</span></div></div>
          </div>
        </div>
        <div class="compose"><div class="to">To: Maya</div><span class="typed"></span><span class="caret"></span></div>
        <div class="orb"><div class="wave"><i></i><i></i><i></i><i></i><i></i></div><span class="orb-text">listening</span></div>
        <svg class="pointer" viewBox="0 0 18 18"><path d="M2 1 L16 8 L9 10 L6 17 Z" fill="#F0452B"/></svg>
        <div class="bubble"></div>
      </div>
    </div>
    <div class="base"></div>
  </div>
  <p class="caption" id="demo-caption">You hold ⌃⌥ and ask. It flies out of the notch and shows you. Hold fn and talk: it types where your cursor is.</p>
</div>
```

- [ ] **Step 3: The laptop CSS**

Append to `assets/site.css`:
```css
.stage { width: min(900px, 92vw); margin: 40px auto 0; }
.laptop { position: relative; }
.lid { background: #1b1b1d; border-radius: 18px 18px 6px 6px; padding: 12px 12px 14px; box-shadow: 0 0 0 1.5px #3a3a3e inset, 0 30px 70px rgba(0, 0, 0, .18); }
.screen { position: relative; aspect-ratio: 16 / 10; border-radius: 8px; overflow: hidden; background: linear-gradient(160deg, #F7C9A9 0%, #E9A8A0 35%, #9AA9D6 75%, #7C8CC9 100%); container-type: inline-size; font-size: clamp(7px, 1.35cqi, 12px); text-align: left; }
.base { height: 14px; margin: 0 -6%; background: linear-gradient(#cfcfd3, #9b9ba1); border-radius: 0 0 14px 14px; position: relative; }
.base::before { content: ""; position: absolute; left: 50%; top: 0; width: 14%; height: 5px; transform: translateX(-50%); background: #8a8a90; border-radius: 0 0 6px 6px; }
.caption { color: var(--ink-3); font-size: 14px; text-align: center; margin: 22px 0 0; min-height: 1.6em; }

.menubar { position: absolute; inset: 0 0 auto 0; height: 4.6%; background: rgba(255, 255, 255, .35); display: flex; align-items: center; padding: 0 1.4%; gap: 1.6%; color: #1f1f1f; z-index: 2; }
.menubar-right { margin-left: auto; }
.apple { width: .9em; height: .9em; border-radius: 50%; background: #1f1f1f; }

.island { position: absolute; top: 0; left: 50%; transform: translateX(-50%); width: 15%; height: 4.6%; background: #000; border-radius: 0 0 1.4cqi 1.4cqi; z-index: 20; color: #fff; overflow: hidden; display: flex; align-items: flex-end; transition: width .55s cubic-bezier(.2, .9, .25, 1.15), height .55s cubic-bezier(.2, .9, .25, 1.15); }
.island.open { width: 50%; height: 16%; border-radius: 0 0 2.6cqi 2.6cqi; }
.island-content { opacity: 0; transition: opacity .25s; display: flex; align-items: center; gap: 1.4cqi; padding: 0 2cqi 1.6cqi; width: 100%; font-size: 1.15em; }
.island.open .island-content { opacity: 1; transition-delay: .25s; }
.said { white-space: nowrap; overflow: hidden; }
.keys { margin-left: auto; color: #9a9a9a; font-size: .85em; white-space: nowrap; }
.wave { display: flex; gap: .25em; align-items: center; height: 1.6em; }
.wave i { display: block; width: .25em; border-radius: 2px; background: var(--pointer); height: .4em; animation: wave-bar .9s ease-in-out infinite; }
.wave i:nth-child(2) { animation-delay: .1s; } .wave i:nth-child(3) { animation-delay: .2s; } .wave i:nth-child(4) { animation-delay: .3s; } .wave i:nth-child(5) { animation-delay: .15s; }
@keyframes wave-bar { 0%, 100% { height: .4em; } 50% { height: 1.5em; } }

.win { position: absolute; left: 14%; top: 14%; width: 62%; height: 72%; background: #FBFAF8; border-radius: 1.1cqi; box-shadow: 0 18px 50px rgba(30, 20, 40, .28); overflow: hidden; color: #222; display: flex; }
.lights { position: absolute; top: 2.4%; left: 1.6%; display: flex; gap: .4em; }
.lights i { width: .8em; height: .8em; border-radius: 50%; background: #ff5f57; } .lights i:nth-child(2) { background: #febc2e; } .lights i:nth-child(3) { background: #28c840; }
.side { width: 34%; background: #EFEDEA; padding: 9% 1.2% 1.2%; display: flex; flex-direction: column; gap: .15em; }
.side > div { padding: .45em .7em; border-radius: .5em; display: flex; align-items: center; gap: .7em; white-space: nowrap; }
.side > div.active { background: #d9d6d1; }
.dot { width: 1.2em; height: 1.2em; border-radius: .35em; flex: none; }
.dot-blue { background: #3b82f6; } .dot-red { background: #ef4444; } .dot-purple { background: #a855f7; } .dot-green { background: #22c55e; } .dot-grey { background: #9ca3af; }
.main { flex: 1; padding: 9% 3% 3%; position: relative; }
.main h4 { margin: 0 0 .9em; font-size: 1.15em; }
.row { display: flex; justify-content: space-between; background: #fff; border: 1px solid #ebe8e3; border-radius: .6em; padding: .7em .9em; margin-bottom: .5em; }
.pane { transition: opacity .3s; }
.pane[hidden] { display: block; opacity: 0; position: absolute; inset: 9% 3% auto 3%; pointer-events: none; }

.pointer { position: absolute; left: 0; top: 0; width: 2cqi; height: 2cqi; z-index: 30; filter: drop-shadow(0 0 6px rgba(240, 69, 43, .9)); transform-origin: center; opacity: 0; transition: opacity .3s; pointer-events: none; }
.pointer.visible { opacity: 1; }
.bubble { position: absolute; z-index: 31; background: var(--pointer); color: #fff; font-weight: 600; padding: .35em .8em; border-radius: .5em; white-space: nowrap; box-shadow: 0 0 14px rgba(240, 69, 43, .6); transform: scale(.4); opacity: 0; transition: transform .35s cubic-bezier(.2, 1.6, .4, 1), opacity .25s; pointer-events: none; }
.bubble.visible { transform: scale(1); opacity: 1; }

.mark { position: absolute; z-index: 25; pointer-events: none; overflow: visible; }
.mark .outline { fill: none; stroke: var(--pointer); stroke-width: 2; stroke-dasharray: 1; stroke-dashoffset: 1; transition: stroke-dashoffset .7s ease-in-out; }
.mark .fill { opacity: 0; transition: opacity .6s ease-out; }
.mark circle { fill: var(--pointer); transform-box: fill-box; transform-origin: center; transform: scale(0); transition: transform .25s cubic-bezier(.2, 1.8, .4, 1); }
.mark.points circle { transform: scale(1); }
.mark.drawn .outline { stroke-dashoffset: 0; }
.mark.filled .fill { opacity: 1; }
.mark.fade { opacity: 0; transition: opacity .5s; }

.compose { position: absolute; left: 22%; top: 30%; width: 52%; background: #fff; border-radius: 1.1cqi; box-shadow: 0 18px 50px rgba(30, 20, 40, .28); padding: 1.2em 1.4em; font-size: 1.05em; opacity: 0; transition: opacity .4s; z-index: 15; }
.compose.visible { opacity: 1; }
.to { color: #888; border-bottom: 1px solid #eee; padding-bottom: .5em; margin-bottom: .7em; }
.caret { display: inline-block; width: 1.5px; height: 1.1em; background: #222; vertical-align: -.2em; animation: caret-blink 1s steps(1) infinite; }
@keyframes caret-blink { 50% { opacity: 0; } }
.orb { position: absolute; bottom: 3%; left: 50%; transform: translateX(-50%) translateY(10px); background: #111; color: #fff; border-radius: 999px; padding: .5em 1em; display: flex; gap: .7em; align-items: center; opacity: 0; transition: opacity .3s, transform .3s; z-index: 22; }
.orb.visible { opacity: 1; transform: translateX(-50%); }
```

- [ ] **Step 4: The browser part of demo.js**

Append to `assets/demo.js`:
```js
// ---- Browser part. Nothing below runs at import time under Node. ----

export class DemoCancelled extends Error {}

export function createCancellation() {
  return { cancelled: false, cancel() { this.cancelled = true; } };
}

export function sleep(milliseconds, cancellation) {
  return new Promise((resolve, reject) => {
    setTimeout(() => (cancellation.cancelled ? reject(new DemoCancelled()) : resolve()), milliseconds);
  });
}

// Positions are measured at the start of every flight, never cached, so a resized window
// still lands the pointer on its target.
function positionInside(container, element) {
  const containerBox = container.getBoundingClientRect();
  const box = element.getBoundingClientRect();
  return { x: box.left - containerBox.left, y: box.top - containerBox.top, width: box.width, height: box.height };
}

function centreOf(container, element, horizontalFraction = 0.5) {
  const box = positionInside(container, element);
  return { x: box.x + box.width * horizontalFraction, y: box.y + box.height / 2 };
}

function placePointer(pointer, point, scale = 1) {
  const half = pointer.getBoundingClientRect().width / scale / 2 || 9;
  pointer.style.transform = `translate(${point.x - half}px, ${point.y - half}px) scale(${scale})`;
}

export function flyPointer(pointer, from, to, durationMilliseconds, cancellation) {
  const startTime = performance.now();
  return new Promise((resolve, reject) => {
    function step(now) {
      if (cancellation.cancelled) { reject(new DemoCancelled()); return; }
      const eased = easeInOutQuad((now - startTime) / durationMilliseconds);
      placePointer(pointer, arcPoint(from, to, eased), flightScale(eased));
      if (eased < 1) requestAnimationFrame(step); else resolve();
    }
    requestAnimationFrame(step);
  });
}

async function typeInto(element, text, millisecondsPerCharacter, cancellation) {
  element.textContent = "";
  for (const character of text) {
    element.textContent += character;
    await sleep(millisecondsPerCharacter, cancellation);
  }
}

let markGradientCounter = 0;

function createMarkElement(container, targetElement) {
  const geometry = markGeometry(positionInside(container, targetElement));
  const gradientId = `mark-gradient-${markGradientCounter++}`;
  const mark = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  mark.setAttribute("class", "mark");
  mark.setAttribute("width", geometry.width);
  mark.setAttribute("height", geometry.height);
  mark.style.left = `${geometry.left}px`;
  mark.style.top = `${geometry.top}px`;
  const innerWidth = geometry.width - 2, innerHeight = geometry.height - 2;
  mark.innerHTML = `
    <defs><linearGradient id="${gradientId}" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#F0452B" stop-opacity=".38"/>
      <stop offset=".55" stop-color="#FF8A3D" stop-opacity=".22"/>
      <stop offset="1" stop-color="#FFC56B" stop-opacity=".10"/>
    </linearGradient></defs>
    <rect class="fill" x="1" y="1" width="${innerWidth}" height="${innerHeight}" rx="8" fill="url(#${gradientId})"/>
    <rect class="outline" x="1" y="1" width="${innerWidth}" height="${innerHeight}" rx="8" pathLength="1"/>
    ${geometry.corners.map((corner) => `<circle cx="${corner.x}" cy="${corner.y}" r="3"/>`).join("")}`;
  // Set through the CSSOM, not a style attribute: the site's Content-Security-Policy blocks inline style attributes.
  mark.querySelectorAll("circle").forEach((circle, index) => { circle.style.transitionDelay = `${index * 0.08}s`; });
  container.appendChild(mark);
  return mark;
}

// Four corner points pop, the outline is drawn through them, then the gradient fills it.
export async function drawMark(container, targetElement, cancellation) {
  const mark = createMarkElement(container, targetElement);
  await sleep(30, cancellation);
  mark.classList.add("points");
  await sleep(380, cancellation);
  mark.classList.add("drawn");
  await sleep(650, cancellation);
  mark.classList.add("filled");
  await sleep(300, cancellation);
  return mark;
}

function showBubble(bubble, text, nearPoint) {
  bubble.textContent = text;
  bubble.style.left = `${nearPoint.x + 12}px`;
  bubble.style.top = `${nearPoint.y + 8}px`;
  bubble.classList.add("visible");
}

function laptopParts(screen) {
  return {
    island: screen.querySelector(".island"),
    said: screen.querySelector(".island .said"),
    keys: screen.querySelector(".island .keys"),
    wifiPane: screen.querySelector('[data-pane="wifi"]'),
    batteryPane: screen.querySelector('[data-pane="battery"]'),
    batteryRow: screen.querySelector('[data-target="battery"]'),
    healthRow: screen.querySelector('[data-target="health"]'),
    compose: screen.querySelector(".compose"),
    typed: screen.querySelector(".compose .typed"),
    orb: screen.querySelector(".orb"),
    orbText: screen.querySelector(".orb-text"),
    pointer: screen.querySelector(".pointer"),
    bubble: screen.querySelector(".bubble"),
    appName: screen.querySelector(".menubar .app-name"),
  };
}

export function resetLaptop(screen) {
  const parts = laptopParts(screen);
  screen.querySelectorAll(".mark").forEach((mark) => mark.remove());
  parts.island.classList.remove("open");
  parts.said.textContent = "";
  parts.keys.textContent = "⌃ ⌥ held";
  parts.wifiPane.hidden = false;
  parts.batteryPane.hidden = true;
  parts.batteryRow.classList.remove("active");
  parts.compose.classList.remove("visible");
  parts.typed.textContent = "";
  parts.orb.classList.remove("visible");
  parts.pointer.classList.remove("visible");
  parts.bubble.classList.remove("visible");
  parts.appName.textContent = "System Settings";
  screen.dataset.state = "playing";
}

// The frame shown with Reduce Motion on and before JavaScript runs: Battery Health marked.
export function showStillFrame(screen) {
  const parts = laptopParts(screen);
  resetLaptop(screen);
  screen.dataset.state = "still";
  parts.wifiPane.hidden = true;
  parts.batteryPane.hidden = false;
  parts.batteryRow.classList.add("active");
  const mark = createMarkElement(screen, parts.healthRow);
  mark.classList.add("points", "drawn", "filled");
  const healthPoint = centreOf(screen, parts.healthRow, 0.8);
  parts.pointer.classList.add("visible");
  placePointer(parts.pointer, healthPoint);
  showBubble(parts.bubble, "here it is!", healthPoint);
}

export async function runLaptopDemo(screen, onBeat, cancellation) {
  const parts = laptopParts(screen);
  const setBeat = (beat) => { screen.dataset.beat = beat; onBeat(beat); };
  while (true) {
    resetLaptop(screen);
    await sleep(900, cancellation);

    setBeat("ask");
    parts.island.classList.add("open");
    await sleep(500, cancellation);
    await typeInto(parts.said, "where do I check battery health?", 38, cancellation);
    await sleep(500, cancellation);
    parts.keys.textContent = "thinking…";
    await sleep(600, cancellation);
    parts.island.classList.remove("open");

    setBeat("point");
    const notchPoint = centreOf(screen, parts.island);
    placePointer(parts.pointer, notchPoint);
    parts.pointer.classList.add("visible");
    const batteryPoint = centreOf(screen, parts.batteryRow, 0.55);
    await flyPointer(parts.pointer, notchPoint, batteryPoint, 1100, cancellation);
    const batteryMark = await drawMark(screen, parts.batteryRow, cancellation);
    showBubble(parts.bubble, "click this!", batteryPoint);
    await sleep(1300, cancellation);

    parts.bubble.classList.remove("visible");
    batteryMark.classList.add("fade");
    parts.batteryRow.classList.add("active");
    parts.wifiPane.hidden = true;
    parts.batteryPane.hidden = false;
    await sleep(450, cancellation);
    const healthPoint = centreOf(screen, parts.healthRow, 0.8);
    await flyPointer(parts.pointer, centreOf(screen, parts.batteryRow, 0.55), healthPoint, 800, cancellation);
    await drawMark(screen, parts.healthRow, cancellation);
    showBubble(parts.bubble, "here it is!", healthPoint);
    await sleep(2200, cancellation);
    parts.bubble.classList.remove("visible");
    screen.querySelectorAll(".mark").forEach((mark) => mark.classList.add("fade"));
    await flyPointer(parts.pointer, healthPoint, centreOf(screen, parts.island), 900, cancellation);
    parts.pointer.classList.remove("visible");
    await sleep(500, cancellation);

    setBeat("type");
    parts.appName.textContent = "Messages";
    parts.compose.classList.add("visible");
    await sleep(500, cancellation);
    parts.orb.classList.add("visible");
    parts.orbText.textContent = "listening";
    await sleep(1500, cancellation);
    parts.orbText.textContent = "moving your words";
    await sleep(500, cancellation);
    await typeInto(parts.typed, "Found it! Battery health says normal, so no need to replace it yet.", 22, cancellation);
    parts.orbText.textContent = "moved to text box";
    await sleep(1600, cancellation);
    parts.orb.classList.remove("visible");
    await sleep(1400, cancellation);
    setBeat("rest");
  }
}

const laptopCaptions = {
  ask: "You hold ⌃⌥ and ask.",
  point: "It flies out of the notch and shows you.",
  type: "Hold fn and talk: it types where your cursor is.",
  rest: "",
};

function startLaptopDemo() {
  const screen = document.querySelector('.screen[data-demo="laptop"]');
  const caption = document.getElementById("demo-caption");
  if (!screen) return;
  const cancellation = createCancellation();
  runLaptopDemo(screen, (beat) => { caption.textContent = laptopCaptions[beat]; }, cancellation)
    .catch((error) => { if (!(error instanceof DemoCancelled)) throw error; });
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", startLaptopDemo);
  else startLaptopDemo();
}
```

(`startLaptopDemo` is replaced in Task 4 by the visibility- and motion-aware starter.)

- [ ] **Step 5: Run the tests**

Run: `npm test`
Expected: unit tests PASS; page tests PASS on chromium and webkit, including "the laptop demo plays ask → point → type and marks Battery".

- [ ] **Step 6: Watch it**

Run: `npm run serve` and open http://127.0.0.1:4173 in Safari and Chrome. Watch two loops. The pointer must leave from the notch, bow upward, grow mid-flight, and land on Battery and Battery Health; the mark must surround the row it lands on.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "The hero laptop: ask, point and mark, then dictation, on a loop"
```

---

### Task 4: Play only when seen, reduced motion, still frame

**Files:**
- Modify: `assets/demo.js` (replace `startLaptopDemo` and the bottom start block)
- Test: `tests/page.spec.mjs` (append)

**Interfaces:**
- Consumes: `runLaptopDemo`, `resetLaptop`, `showStillFrame`, `createCancellation`, `DemoCancelled` from Task 3.
- Produces: `playWhileVisible(element, startRun: (cancellation) => Promise) → void`: starts a run when ≥ 35 % of `element` is in view and the tab is visible; cancels it when either stops being true; every new run starts from the run's own reset. Task 6 uses it for the closing demo.

- [ ] **Step 1: Write the failing tests**

Append to `tests/page.spec.mjs`:
```js
test.describe("reduced motion", () => {
  test.use({ reducedMotion: "reduce" });
  test("shows the still frame and nothing moves", async ({ page }) => {
    await page.goto("/");
    const screen = page.locator('.screen[data-demo="laptop"]');
    await expect(screen).toHaveAttribute("data-state", "still");
    await expect(screen.locator(".mark.filled")).toHaveCount(1);
    await expect(screen.locator(".bubble")).toHaveText("here it is!");
    const before = await screen.locator(".pointer").getAttribute("style");
    await page.waitForTimeout(3000);
    expect(await screen.locator(".pointer").getAttribute("style")).toBe(before);
    await expect(screen).not.toHaveAttribute("data-beat", /.+/);
    await expect(page.locator("#demo-caption")).toContainText("You hold ⌃⌥ and ask. It flies out of the notch");
  });
});

test("restarts clean after leaving view", async ({ page }) => {
  await page.goto("/");
  const screen = page.locator('.screen[data-demo="laptop"]');
  await expect(screen).toHaveAttribute("data-beat", "point", { timeout: 8000 });
  await page.locator("footer").scrollIntoViewIfNeeded();
  await page.waitForTimeout(600);
  await expect(screen).toHaveAttribute("data-state", "paused");
  await page.locator("h1").scrollIntoViewIfNeeded();
  await expect(screen).toHaveAttribute("data-state", "playing");
  await expect(screen.locator(".mark")).toHaveCount(0);
  await expect(screen.locator(".pointer.visible")).toHaveCount(0);
  await expect(screen).toHaveAttribute("data-beat", "ask", { timeout: 5000 });
});

test("lands on Battery Health after a resize mid-loop", async ({ page }) => {
  await page.goto("/");
  const screen = page.locator('.screen[data-demo="laptop"]');
  await expect(screen).toHaveAttribute("data-beat", "ask", { timeout: 5000 });
  await page.setViewportSize({ width: 1000, height: 800 });
  await expect(page.locator(".bubble")).toHaveText("here it is!", { timeout: 12000 });
  const markBox = await screen.locator(".mark").last().boundingBox();
  const rowBox = await screen.locator('[data-target="health"]').boundingBox();
  expect(Math.abs(markBox.x - rowBox.x)).toBeLessThan(8);
  expect(Math.abs(markBox.y - rowBox.y)).toBeLessThan(8);
});
```

Run: `npx playwright test -g "reduced motion|restarts clean|resize" --project=chromium`
Expected: FAIL (`data-state` stays "playing", demo keeps running off screen).

- [ ] **Step 2: Implement**

In `assets/demo.js`, delete `startLaptopDemo` and the `if (typeof document !== "undefined") { ... }` block, and append:
```js
export function playWhileVisible(element, startRun) {
  let isInView = false;
  let currentCancellation = null;

  function update() {
    const shouldPlay = isInView && document.visibilityState === "visible";
    if (shouldPlay && !currentCancellation) {
      currentCancellation = createCancellation();
      startRun(currentCancellation).catch((error) => { if (!(error instanceof DemoCancelled)) throw error; });
    } else if (!shouldPlay && currentCancellation) {
      currentCancellation.cancel();
      currentCancellation = null;
    }
  }

  new IntersectionObserver((entries) => {
    isInView = entries[0].isIntersecting;
    update();
  }, { threshold: 0.35 }).observe(element);
  document.addEventListener("visibilitychange", update);
}

const stillCaption = "You hold ⌃⌥ and ask. It flies out of the notch and shows you. Hold fn and talk: it types where your cursor is.";

function startDemos() {
  const screen = document.querySelector('.screen[data-demo="laptop"]');
  const caption = document.getElementById("demo-caption");
  if (!screen) return;
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    showStillFrame(screen);
    caption.textContent = stillCaption;
    return;
  }
  playWhileVisible(screen, async (cancellation) => {
    try {
      await runLaptopDemo(screen, (beat) => { caption.textContent = laptopCaptions[beat]; }, cancellation);
    } catch (error) {
      if (error instanceof DemoCancelled) {
        resetLaptop(screen);
        screen.dataset.state = "paused";
        delete screen.dataset.beat;
      }
      throw error;
    }
  });
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", startDemos);
  else startDemos();
}
```

Also, so the page tells the story before JavaScript runs, give the markup the still frame by default: in `index.html` set `hidden` on `[data-pane="wifi"]`, add `class="active"` to `[data-target="battery"]`, and add to `site.css`:
```css
.screen[data-state="still"] .bubble:empty { display: none; }
```
(`showStillFrame` adds the mark, the pointer and the bubble; with no JavaScript the Battery pane alone shows, which still reads correctly.)

- [ ] **Step 3: Run the tests**

Run: `npm test`
Expected: all PASS on chromium and webkit.

- [ ] **Step 4: Check by hand**

System Settings → Accessibility → Display → Reduce motion on; reload in Safari: the still frame, nothing moves. Turn it off again. Switch tabs mid-flight and back: the demo restarts from the beginning.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "The demo plays only while seen, restarts clean, and holds a still frame for Reduce Motion"
```

---

### Task 5: What it does, private by default, open source (with the star count)

**Files:**
- Modify: `index.html` (sections `#what`, `#private`, `#open-source`)
- Modify: `assets/site.css` (append)
- Create: `assets/stars.js`
- Create: `assets/media/point.jpg`, `assets/media/dictate.jpg`, `assets/media/agent.jpg`
- Test: `tests/page.spec.mjs` (append), `tests/unit/stars.test.mjs`

**Interfaces:**
- Produces: `formatStarCount(count: unknown) → string | null` exported from `assets/stars.js` (`1234 → "1.2k"`, `87 → "87"`, anything not a non-negative finite number → `null`); `#star-count` filled only when that returns a string.

- [ ] **Step 1: Write the failing tests**

`tests/unit/stars.test.mjs`:
```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { formatStarCount } from "../../assets/stars.js";

test("star counts read like GitHub's", () => {
  assert.equal(formatStarCount(87), "87");
  assert.equal(formatStarCount(999), "999");
  assert.equal(formatStarCount(1234), "1.2k");
  assert.equal(formatStarCount(15000), "15k");
});

test("anything that is not a count gives nothing to show", () => {
  for (const bad of [undefined, null, "12", NaN, -1, Infinity]) assert.equal(formatStarCount(bad), null);
});
```

Append to `tests/page.spec.mjs`:
```js
test("the open-source section reads fine when the GitHub API fails", async ({ page }) => {
  await page.route("https://api.github.com/**", (route) => route.abort());
  await page.goto("/");
  const section = page.locator("#open-source");
  await expect(section).toContainText("MIT");
  await expect(section).not.toContainText("undefined");
  await expect(section).not.toContainText("NaN");
  await expect(page.locator("#star-count")).toBeHidden();
});

test("the star count shows when GitHub answers", async ({ page }) => {
  await page.route("https://api.github.com/repos/prasanthsasikumar/openclicky", (route) =>
    route.fulfill({ json: { stargazers_count: 1234 } }));
  await page.goto("/");
  await expect(page.locator("#star-count")).toHaveText("★ 1.2k");
});

test("three cards: point, dictate, hand off a task", async ({ page }) => {
  await page.goto("/");
  const cards = page.locator("#what .card h3");
  await expect(cards).toHaveText(["Point", "Dictate", "Hand off a task"]);
  for (const image of await page.locator("#what img").all()) await expect(image).toHaveAttribute("alt", /.{10,}/);
});
```

Run: `npm test`
Expected: FAIL (no `stars.js`, no cards).

- [ ] **Step 2: Stills**

```bash
cd ~/Documents/GitHub/openclicky-site
sips -Z 1200 -s format jpeg -s formatOptions 78 ../openclicky/docs/media/point-at.jpg --out assets/media/point.jpg
sips -Z 1200 -s format jpeg -s formatOptions 78 ../openclicky/docs/media/dictation-record.jpg --out assets/media/dictate.jpg
sips -Z 1200 -s format jpeg -s formatOptions 78 ../openclicky/docs/media/hud-home.jpg --out assets/media/agent.jpg
ls -la assets/media   # each under 250 KB; if not, drop formatOptions to 65
```

Open each image and check it shows nothing private (names, emails, other people's messages). If one does, stop and ask Prasanth for a replacement rather than shipping it.

- [ ] **Step 3: Markup**

Replace the three section bodies in `index.html`:
```html
<section id="what" class="section">
  <h2>What it does</h2>
  <div class="cards">
    <article class="card">
      <img src="/assets/media/point.jpg" alt="OpenClicky's orange pointer resting beside a control it was asked to find, with a 'right here!' bubble" loading="lazy" width="1200" height="750">
      <h3>Point</h3>
      <p>Hold ⌃⌥ and ask about anything on your screen. The pointer flies there and marks it, then says what to do.</p>
    </article>
    <article class="card">
      <img src="/assets/media/dictate.jpg" alt="The record page: where your voice goes, the take box and your recent takes" loading="lazy" width="1200" height="750">
      <h3>Dictate</h3>
      <p>Hold fn in any text box and talk. Your words are cleaned up in the style of the app in front. Eleven Indian languages with Sarvam.</p>
    </article>
    <article class="card">
      <img src="/assets/media/agent.jpg" alt="The notch island open on its home tab, with skills and shortcuts" loading="lazy" width="1200" height="750">
      <h3>Hand off a task</h3>
      <p>Say what you want done and a Codex agent does the work on your Mac, then tells you when it is finished.</p>
    </article>
  </div>
</section>

<section id="private" class="section">
  <h2>Private by default</h2>
  <ul class="points">
    <li><strong>Dictation works offline.</strong> Apple's on-device recogniser hears you; nothing leaves your Mac.</li>
    <li><strong>Your keys go straight to the vendor.</strong> Add an OpenAI or Anthropic key and requests go directly to them, never through us.</li>
    <li><strong>No key? A free account.</strong> Type your email in the app. No password, no card.</li>
  </ul>
</section>

<section id="open-source" class="section">
  <h2>Open source</h2>
  <p class="open-source-line">MIT licensed. Read every line, change what you like.</p>
  <div class="ctas ctas-left">
    <a class="btn btn-ghost" href="https://github.com/prasanthsasikumar/openclicky">View on GitHub <span id="star-count" hidden></span></a>
    <a class="btn btn-ghost" href="https://github.com/prasanthsasikumar/openclicky/blob/main/CONTRIBUTING.md">Contributions welcome</a>
  </div>
</section>
```

Add `<script type="module" src="/assets/stars.js"></script>` in `<head>` after the demo script.

- [ ] **Step 4: stars.js**

```js
export function formatStarCount(count) {
  if (typeof count !== "number" || !Number.isFinite(count) || count < 0) return null;
  if (count < 1000) return String(count);
  const thousands = count / 1000;
  return `${thousands < 10 ? Math.floor(thousands * 10) / 10 : Math.floor(thousands)}k`;
}

async function showStarCount() {
  const starCount = document.getElementById("star-count");
  if (!starCount) return;
  try {
    const response = await fetch("https://api.github.com/repos/prasanthsasikumar/openclicky");
    if (!response.ok) return;
    const formatted = formatStarCount((await response.json()).stargazers_count);
    if (!formatted) return;
    starCount.textContent = `★ ${formatted}`;
    starCount.hidden = false;
  } catch {
    // Offline, blocked or rate-limited: the button reads fine without a number.
  }
}

if (typeof document !== "undefined") showStarCount();
```

- [ ] **Step 5: CSS**

Append to `assets/site.css`:
```css
.cards { display: grid; grid-template-columns: repeat(3, 1fr); gap: 24px; }
.card { background: #fff; border-radius: 18px; overflow: hidden; box-shadow: 0 6px 24px rgba(0, 0, 0, .06); }
.card img { display: block; width: 100%; height: auto; aspect-ratio: 16 / 10; object-fit: cover; background: var(--paper-deep); }
.card h3 { margin: 18px 20px 6px; font-size: 19px; }
.card p { margin: 0 20px 22px; color: var(--ink-2); font-size: 15px; }
.points { list-style: none; padding: 0; margin: 0; display: grid; grid-template-columns: repeat(3, 1fr); gap: 24px; }
.points li { color: var(--ink-2); }
.points strong { display: block; color: var(--ink); font-size: 17px; margin-bottom: 4px; }
.open-source-line { color: var(--ink-2); margin: 0 0 20px; }
.ctas-left { justify-content: flex-start; }
@media (max-width: 820px) { .cards, .points { grid-template-columns: 1fr; } }
```

- [ ] **Step 6: Run the tests**

Run: `npm test`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "What it does, private by default, and open source with a star count that fails quietly"
```

---

### Task 6: Try it on this page, and phones

**Files:**
- Modify: `index.html` (`#try`)
- Modify: `assets/site.css` (append)
- Modify: `assets/demo.js` (append `runPageDemo` and start it in `startDemos`)
- Test: `tests/page.spec.mjs` (append)

**Interfaces:**
- Consumes: `playWhileVisible`, `flyPointer`, `drawMark`, `sleep`, `DemoCancelled` (Tasks 3–4).
- Produces: `runPageDemo(section, cancellation)`; DOM contract `#try[data-demo="page"]` with `.island`, `.said`, `.keys`, `.pointer`, `.bubble`, `[data-target="download"]`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/page.spec.mjs`:
```js
test("the closing demo marks this page's Download button", async ({ page }) => {
  await page.goto("/");
  await page.locator("#try").scrollIntoViewIfNeeded();
  await expect(page.locator("#try .said")).toHaveText("how do I get this on my Mac?", { timeout: 6000 });
  await expect(page.locator("#try .bubble")).toHaveText("start here!", { timeout: 6000 });
  const markBox = await page.locator("#try .mark").boundingBox();
  const buttonBox = await page.locator('#try [data-target="download"]').boundingBox();
  expect(Math.abs(markBox.x + 4 - buttonBox.x)).toBeLessThan(6);
});

test.describe("phone", () => {
  test.use({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  test("no sideways scrolling, a Mac-specific button and the install note", async ({ page }) => {
    await page.goto("/");
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(overflow).toBeLessThanOrEqual(0);
    await expect(page.locator("#hero .btn-primary .label-narrow")).toBeVisible();
    await expect(page.locator("#hero .btn-primary .label-wide")).toBeHidden();
    await expect(page.locator("#hero .phone-note")).toBeVisible();
    await expect(page.locator("#try .page-demo")).toBeHidden();
    await expect(page.locator("#try .btn-primary")).toBeVisible();
  });
});
```

(`isMobile` is Chromium-only; run the phone test with `--project=chromium`. In `playwright.config.mjs`, add `grepInvert: /phone/` to the webkit project.)

Run: `npx playwright test -g "closing demo|phone" --project=chromium`
Expected: FAIL.

- [ ] **Step 2: Markup**

Replace `#try` in `index.html`:
```html
<section id="try" class="section try" data-demo="page">
  <div class="page-demo" aria-hidden="true">
    <div class="island"><div class="island-content"><div class="wave"><i></i><i></i><i></i><i></i><i></i></div><span class="said"></span><span class="keys">⌃ ⌥ held</span></div></div>
    <svg class="pointer" viewBox="0 0 18 18"><path d="M2 1 L16 8 L9 10 L6 17 Z" fill="#F0452B"/></svg>
    <div class="bubble"></div>
  </div>
  <h2>Try it on this page</h2>
  <p class="try-line">This is what it does on your Mac, only there it points at your apps instead of a web page.</p>
  <a class="btn btn-primary" data-target="download" href="/download"><span class="label-wide">Download for macOS</span><span class="label-narrow">Download for Mac</span></a>
  <p class="requirements">macOS 14.2 or later · Apple Silicon and Intel · notarized</p>
</section>
```

- [ ] **Step 3: CSS**

Append to `assets/site.css`:
```css
.try { position: relative; text-align: center; background: radial-gradient(120% 90% at 50% 0%, #2a2522 0%, #141210 65%); color: #EDE9E1; border-radius: 28px; padding: 120px 24px 80px; margin-top: 96px; overflow: hidden; container-type: inline-size; font-size: 14px; }
.try h2 { color: #EDE9E1; }
.try-line { color: #b0aa9f; max-width: 520px; margin: 0 auto 28px; }
.try .btn-primary { background: #EDE9E1; color: #141210; }
.try .requirements { color: #8e877b; }
.page-demo .island { width: 20%; height: 26px; }
.page-demo .island.open { width: 56%; height: 72px; border-radius: 0 0 22px 22px; }
.page-demo .island-content { font-size: 14px; }
.page-demo .pointer { width: 18px; height: 18px; }

@media (max-width: 640px) {
  .label-wide { display: none; }
  .label-narrow { display: inline; }
  .phone-note { display: block; color: var(--ink-2); font-size: 14px; margin: 6px 0 0; }
  .nav-links a[href="#what"] { display: none; }
  .page-demo { display: none; }
  .try { padding-top: 64px; }
  .stage { width: 100%; }
}
```

- [ ] **Step 4: runPageDemo**

Append to `assets/demo.js` (above `startDemos`):
```js
export async function runPageDemo(section, cancellation) {
  const island = section.querySelector(".island");
  const said = section.querySelector(".said");
  const keys = section.querySelector(".keys");
  const pointer = section.querySelector(".pointer");
  const bubble = section.querySelector(".bubble");
  const downloadButton = section.querySelector('[data-target="download"]');
  try {
    while (true) {
      section.querySelectorAll(".mark").forEach((mark) => mark.remove());
      keys.textContent = "⌃ ⌥ held";
      said.textContent = "";
      await sleep(800, cancellation);
      island.classList.add("open");
      await sleep(500, cancellation);
      await typeInto(said, "how do I get this on my Mac?", 38, cancellation);
      keys.textContent = "thinking…";
      await sleep(700, cancellation);
      island.classList.remove("open");
      const notchPoint = centreOf(section, island);
      placePointer(pointer, notchPoint);
      pointer.classList.add("visible");
      const buttonPoint = centreOf(section, downloadButton, 0.7);
      await flyPointer(pointer, notchPoint, buttonPoint, 1300, cancellation);
      await drawMark(section, downloadButton, cancellation);
      showBubble(bubble, "start here!", buttonPoint);
      await sleep(3600, cancellation);
      bubble.classList.remove("visible");
      section.querySelectorAll(".mark").forEach((mark) => mark.classList.add("fade"));
      await flyPointer(pointer, buttonPoint, centreOf(section, island), 1000, cancellation);
      pointer.classList.remove("visible");
      await sleep(2500, cancellation);
    }
  } finally {
    // A cancelled run leaves nothing behind; the next run starts clean.
    section.querySelectorAll(".mark").forEach((mark) => mark.remove());
    island.classList.remove("open");
    pointer.classList.remove("visible");
    bubble.classList.remove("visible");
  }
}
```

In `startDemos`, after the reduced-motion early return (so reduced motion never starts it), add:
```js
  const trySection = document.querySelector('#try[data-demo="page"]');
  if (trySection && window.matchMedia("(min-width: 641px)").matches) {
    playWhileVisible(trySection, (cancellation) => runPageDemo(trySection, cancellation));
  }
```

- [ ] **Step 5: Run the tests**

Run: `npm test`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Try it on this page: the pointer marks the Download button; phones get a plain Download block"
```

---

### Task 7: Social card, meta tags, weight budget

**Files:**
- Create: `assets/og-image.png` (1200×630)
- Modify: `index.html` (`<head>`)
- Test: `tests/page.spec.mjs` (append), `tests/unit/weight.test.mjs`

- [ ] **Step 1: Write the failing tests**

`tests/unit/weight.test.mjs`:
```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, statSync } from "node:fs";
import { gzipSync } from "node:zlib";

test("HTML + CSS + JS stay under 60 KB gzipped", () => {
  const files = ["index.html", "assets/site.css", "assets/demo.js", "assets/stars.js"];
  const total = files.reduce((sum, file) => sum + gzipSync(readFileSync(file)).length, 0);
  assert.ok(total < 60 * 1024, `${total} bytes gzipped`);
});

test("the first screen stays under 300 KB (code, mark, no lazy images)", () => {
  const files = ["index.html", "assets/site.css", "assets/demo.js", "assets/stars.js", "assets/mark.svg"];
  const total = files.reduce((sum, file) => sum + statSync(file).size, 0);
  assert.ok(total < 300 * 1024, `${total} bytes`);
});

test("the social card is under 300 KB", () => {
  assert.ok(statSync("assets/og-image.png").size < 300 * 1024);
});
```

Append to `tests/page.spec.mjs`:
```js
test("link previews have a title, description and image", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator('meta[property="og:title"]')).toHaveAttribute("content", "OpenClicky: ask your Mac, it shows you where");
  await expect(page.locator('meta[property="og:image"]')).toHaveAttribute("content", "https://openclicky.flowsxr.com/assets/og-image.png");
  await expect(page.locator('meta[name="twitter:card"]')).toHaveAttribute("content", "summary_large_image");
});
```

Run: `npm test` — Expected: FAIL.

- [ ] **Step 2: Make the social card from the still frame**

```bash
npm run serve &
SERVER=$!
cat > og.tmp.mjs <<'EOF'
import { chromium } from "@playwright/test";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, reducedMotion: "reduce", deviceScaleFactor: 1 });
await page.goto("http://127.0.0.1:4173/");
await page.addStyleTag({ content: ".site-nav,.lede,.ctas,.requirements,.caption,main>section:not(#hero),footer{display:none!important} h1{font-size:46px;margin-top:28px} .stage{width:620px;margin-top:18px}" });
await page.screenshot({ path: "assets/og-image.png" });
await browser.close();
EOF
node og.tmp.mjs && rm og.tmp.mjs
kill $SERVER
```

Open `assets/og-image.png` and check: headline readable, laptop with Battery Health marked, no cut-off text.

- [ ] **Step 3: Meta tags**

Add to `<head>` in `index.html`:
```html
<link rel="canonical" href="https://openclicky.flowsxr.com/">
<meta name="theme-color" content="#F4F1EA">
<meta property="og:type" content="website">
<meta property="og:url" content="https://openclicky.flowsxr.com/">
<meta property="og:title" content="OpenClicky: ask your Mac, it shows you where">
<meta property="og:description" content="Ask out loud and a pointer flies out of the notch to the answer on your screen. Free and open source for macOS.">
<meta property="og:image" content="https://openclicky.flowsxr.com/assets/og-image.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
```

- [ ] **Step 4: Run the tests**

Run: `npm test` — Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Social card from the still frame, link-preview tags, weight budget tests"
```

---

### Task 8: Netlify site, continuous deploys, preview checks

**Files:**
- Create: `.netlify/state.json` (git-ignored, written by the CLI)
- Modify: `README.md` (add the live preview URL)

- [ ] **Step 1: Create the site and link the repo**

```bash
cd ~/Documents/GitHub/openclicky-site
npx netlify-cli sites:create --name openclicky --account-slug "$(npx netlify-cli api listAccountsForUser | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["slug"])')"
npx netlify-cli link --name openclicky
npx netlify-cli deploy --prod --dir .
```
If the name `openclicky` is taken on netlify.app, use `openclicky-site`.

Continuous deployment from GitHub (deploys on push, previews on pull requests) needs the Netlify GitHub app on the repo: run `npx netlify-cli init` and choose "Connect this directory to an existing Netlify site"; if it asks to authorise GitHub in the browser, Prasanth clicks Authorize. Then push an empty commit and check `npx netlify-cli api listSiteDeploys --data '{"site_id":"<id>"}'` shows a deploy from `main`.

- [ ] **Step 2: Check the live preview**

```bash
URL=https://openclicky.netlify.app
curl -sI $URL/ | head -1                              # HTTP/2 200
curl -sI $URL/download | grep -i '^location'          # .../openclicky/releases/latest
curl -sI $URL/ | grep -iE 'content-security-policy|x-content-type-options'
npx -y lighthouse $URL --quiet --chrome-flags="--headless=new" --only-categories=performance,accessibility,best-practices,seo --output=json --output-path=./lighthouse.json
python3 -c "import json;d=json.load(open('lighthouse.json'));print({k:round(v['score']*100) for k,v in d['categories'].items()})"
rm lighthouse.json
```
Expected: 200; the redirect location; both headers; every Lighthouse score ≥ 95. A score under 95: fix what Lighthouse names, commit, redeploy, re-run. Do not continue below 95.

- [ ] **Step 3: Check by eye**

Open the preview in Safari and Chrome; watch the hero twice round; scroll to the closing demo; Reduce Motion on, reload; a 390-px-wide window. Paste the preview URL into a Messages or Slack draft (not sent) to see the social card.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Netlify site linked; preview at openclicky.netlify.app"
git push
```

---

### Task 9 (gated): openclicky.flowsxr.com goes live

**Gate:** an OpenClicky release that draws the mark (points, outline, gradient fill) is on GitHub releases. Until then, stop after Task 8 and tell Prasanth the preview URL.

- [ ] **Step 1: Attach the domain**

```bash
cd ~/Documents/GitHub/openclicky-site
SITE_ID=$(python3 -c "import json;print(json.load(open('.netlify/state.json'))['siteId'])")
npx netlify-cli api updateSite --data "{\"site_id\":\"$SITE_ID\",\"body\":{\"custom_domain\":\"openclicky.flowsxr.com\"}}"
```
Netlify DNS hosts flowsxr.com, so the record is created with the domain. Check: `dig +short openclicky.flowsxr.com` returns Netlify's load balancer, and `curl -sI https://openclicky.flowsxr.com | head -1` returns `HTTP/2 200` once the certificate is issued (can take a few minutes; `npx netlify-cli api provisionSiteTLSCertificate --data "{\"site_id\":\"$SITE_ID\"}"` if it has not after 10).

- [ ] **Step 2: Re-run Task 8 Step 2 against https://openclicky.flowsxr.com**

- [ ] **Step 3: Record it**

Add `openclicky.flowsxr.com → Netlify site openclicky (repo prasanthsasikumar/openclicky-site)` to `~/Documents/GitHub/flowsxr-hq/projects/index.md` and commit there.

---

### Task 10: README leads with pointing (openclicky repo)

**Files:**
- Modify: `~/Documents/GitHub/openclicky/README.md` (the opening paragraph, the demo caption, and the order of the first sections)

- [ ] **Step 1: Branch**

```bash
cd ~/Documents/GitHub/openclicky
git switch -c docs/readme-pointing-first
```

- [ ] **Step 2: Rewrite the opening**

Replace the first paragraph (from `**Dictation for your Mac that never has to leave it.**` to `MIT licensed.`) with:
```markdown
**Ask your Mac. It shows you where.** Hold ⌃ control + ⌥ option anywhere and ask out loud ("where do I
check battery health?"): a pointer flies out of the notch and lands on the answer on your screen. Hold
fn and talk, and your words are typed where your cursor is, cleaned up in the style of the app in front:
offline by default with Apple's on-device recogniser, eleven Indian languages with your Sarvam key. And
when it is more than a question, hand the task to a Codex agent. MIT licensed.
```
Add `· [Website](https://openclicky.flowsxr.com)` to the links line after "Download OpenClicky for macOS" (only once Task 9 is live; until then leave the link out).

Move the companion paragraph that starts `The companion features are unchanged:` up so it comes straight after "Try it in three steps", under a heading `### Ask and get pointed at it`, reworded from "The companion features are unchanged:" to "Hold **⌃ control + ⌥ option** and ask about anything on screen…" (keep the rest of its sentences). Step 2 of "Try it in three steps" becomes the ⌃⌥ question; the fn step becomes step 3; the window step is folded into the end of step 3.

- [ ] **Step 3: Check**

Run: `grep -n "Dictation for your Mac that never has to leave it" README.md` — Expected: no output. Read the top 40 lines through once: pointing comes first, dictation second, the agent third, and nothing claims the drawn mark until that release exists.

- [ ] **Step 4: Commit (do not push without asking)**

```bash
git add README.md docs/superpowers/specs/2026-10-11-openclicky-website-design.md docs/superpowers/plans/2026-10-11-openclicky-website.md
git commit -m "README leads with pointing, like the website; website spec and plan"
```

---

### Task 11: Discord setup doc (openclicky repo)

**Files:**
- Create: `~/Documents/GitHub/openclicky/docs/launch/discord-setup.md`

- [ ] **Step 1: Write the doc**

```markdown
# The OpenClicky Discord

Prasanth creates the server (Discord → + → Create My Own → For a club or community) and pastes the
text below. Then: Server Settings → Enable Community (gives #rules and an announcement channel type).

**Name:** OpenClicky · **Icon:** `macos/OpenClicky/OpenClicky/Assets.xcassets/AppIcon.appiconset` 512 px

## Channels

INFO
- #rules (read-only)
- #announcements (announcement channel; release notes go here, followable by other servers)

COMMUNITY
- #general
- #show-and-tell (screen recordings of what it pointed at, skills you made)
- #feature-requests (forum channel; tags: pointing, dictation, agent, languages, windows)

SUPPORT
- #help (forum channel; tags: install, permissions, keys-and-account, dictation, pointing; post template below)
- #bugs (forum channel; asks for the version and `~/Library/Logs/OpenClicky/app.log` lines, never keys)

BUILDING
- #contributors (for people working on the code; links CONTRIBUTING.md)

## Roles

- **Maintainer** (Prasanth): manage messages, manage threads.
- **Contributor**: given by hand to anyone with a merged pull request; can post in #contributors.
- **@everyone**: read all, post everywhere except #rules and #announcements.

## Welcome message (Server Settings → Onboarding → Welcome)

> Welcome to OpenClicky. It is the Mac helper that points: hold ⌃⌥, ask out loud, and a pointer flies
> to the answer on your screen. Stuck? Post in #help with your macOS version and what you asked.
> Made something with it? #show-and-tell. Download: https://openclicky.flowsxr.com/download

## Rules

1. Be kind. People here range from first-time Mac users to people writing Swift.
2. Never post API keys, account tokens or `~/.openclicky/shell.json`. Redact them in logs.
3. Screenshots of your screen can show more than you mean to: crop to what matters.
4. Bugs with steps to reproduce go in #bugs; questions in #help.
5. English or any language you like; say which so others can help.

## #help post template

> **What I asked or did:**
> **What happened:**
> **What I expected:**
> **macOS version / OpenClicky version (menu bar → about):**

## Invite

Server Settings → Invites → Create: never expires, no use limit. Put it in the website's
`netlify.toml`:

    [[redirects]]
      from = "/discord"
      to = "https://discord.gg/<code>"
      status = 302

and add the "Join the Discord" buttons back to the hero and the nav/footer (`href="/discord"`); update
the Task 1 test "no Discord link while the invite does not exist" to expect the links instead.
```

- [ ] **Step 2: Commit**

```bash
git add docs/launch/discord-setup.md
git commit -m "Discord setup: channels, roles, welcome, rules and how the invite reaches the website"
```
