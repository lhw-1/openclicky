# openclicky.flowsxr.com: the website

2026-10-11. Approved in conversation; this file records it.

## Goal

Someone lands on the page and, inside ten seconds, has seen what OpenClicky does: you ask your Mac out
loud and a pointer flies out of the notch and marks the answer on your screen. Everything else on the
page (dictation, the agent, privacy, open source) comes after that one idea. Success is a visitor who
can say "it points at things on my screen when I ask" and who clicks Download.

Pointing leads, not dictation. The moment a test user was won over was the pointer showing her where
things were; dictation alone looks like Wispr Flow or Superwhisper.

## What it is not

- No sign-up, account or payment on the site. The free account is created inside the app.
- No docs, blog or changelog at launch. GitHub holds those.
- No cookies, so no cookie banner (analytics is cookieless; see below).

## Repository and hosting

- New public repo `prasanthsasikumar/openclicky-site`, MIT, plain HTML, CSS and JavaScript in `public/`
  (the only folder Netlify publishes). No framework, no build step, no npm dependencies at runtime.
- Netlify site deployed from `main`; every pull request gets a deploy preview. The Netlify login on this
  Mac (personal account, `netlify-cli`) already manages the `flowsxr.com` DNS zone.
- `openclicky.flowsxr.com` is added as the site's custom domain; Netlify DNS gets the record and issues
  the certificate.
- `netlify.toml`:
  - `/download` redirects (302) to `https://github.com/prasanthsasikumar/openclicky/releases/latest`, so
    the button never goes stale. Every Download button links to `/download`.
  - `/discord` redirects (302) to the Discord invite once it exists; until then the Discord links are
    hidden (see the Discord section).
  - Long cache on `/assets/*` (file names carry a content hash or a version), short cache on HTML.
  - Headers: `Content-Security-Policy` allowing only self and the GitHub API, `Referrer-Policy:
    strict-origin-when-cross-origin`, `X-Content-Type-Options: nosniff`, `Permissions-Policy` empty.

Layout:

```
openclicky-site/
  index.html
  assets/
    site.css
    demo.js            the laptop demo and the closing "try it on this page" demo
    stars.js           GitHub star count, optional enhancement
    media/             stills and short clips from openclicky/docs/media, re-encoded
    og-image.png       1200×630 social card: the laptop frame with the mark on "Battery Health"
  netlify.toml
  README.md
  LICENSE
```

## The page, top to bottom

Palette and type follow the app: paper `#F4F1EA`, ink `#22201C`, pointer `#F0452B`, system font stack.
The brand mark is the app's ring with a square top-right corner and a pointer (`OpenClickyMark`),
redrawn as inline SVG.

1. **Navigation.** Mark + "openclicky", then How it works (anchor to section 2), GitHub, Discord.
2. **Hero (direction A from the mockups).**
   - Headline "Ask your Mac. / It shows you where." (second line in pointer orange).
   - One line: "Hold ⌃⌥ and ask out loud. A pointer flies out of the notch and marks the answer on your
     screen. Hold fn and talk, and it types for you. Free and open source."
   - Buttons: "Download for macOS" (`/download`) and "Join the Discord".
   - Under them, a small line: "macOS 14.2 or later · Apple Silicon and Intel · notarized".
   - The laptop: a lid with a notch, a screen with a menu bar, a System Settings window, the island,
     the pointer, a caption line under the laptop. The demo loop (about 16 s):
     1. The island opens and types "where do I check battery health?", then "thinking…", then closes.
     2. The pointer leaves the notch on a bezier arc that lifts above the straight line and grows
        mid-flight (as `OverlayWindow.animateBezierFlightArc` does), lands on **Battery**, and draws the
        mark: four corner points pop, the outline is drawn through them, the gradient fills it. A
        "click this!" bubble pops.
     3. The pane changes to Battery; the pointer hops to **Battery Health**, marks it, "here it is!".
     4. The pointer flies home into the notch.
     5. A Messages compose window; the orb at the bottom goes listening → "moving your words" → the
        sentence types out → "moved to text box".
   - The caption names each beat: "You hold ⌃⌥ and ask." / "It flies out of the notch and shows you." /
     "Hold fn and talk: it types where your cursor is."
3. **Three things it does.** Three cards, each a short muted looping clip (or a still if no clip
   exists yet) and two lines of copy: **Point** (ask about anything on screen), **Dictate** (fn
   anywhere, cleaned up in the style of the app in front, eleven Indian languages with Sarvam),
   **Hand off a task** (the Codex agent does the work). Stills come from `openclicky/docs/media`.
4. **Private by default.** Three short points: dictation works offline with Apple's on-device
   recogniser; your own OpenAI or Anthropic key goes straight to the vendor, never through us; no key? a
   free account works with no password.
5. **Open source.** MIT, a link to the repo, the star count (fetched from the GitHub API on load; the
   section reads fine without it), "Contributions welcome" linking to CONTRIBUTING.md.
6. **Try it on this page.** Direction B's trick: a small notch at the top of this section; when the
   section scrolls into view the island types "how do I get this on my Mac?", the pointer flies down
   and marks this section's Download button, "start here!".
7. **Footer.** GitHub, Releases, Discord, Privacy (links to the privacy section of the README), "Made by
   FlowsXR" linking to flowsxr.com.

## Search and analytics (added 2026-10-11, during the build)

The link will be shared and searched a lot, so:

- **Search:** `robots.txt`, `sitemap.xml`, canonical URL, Open Graph and Twitter cards, a
  `SoftwareApplication` JSON-LD block (free, macOS 14.2+, MIT, download URL), an apple-touch-icon.
  Google Search Console verification is a DNS TXT record on flowsxr.com once Prasanth starts it.
- **Analytics: PostHog, cookieless** (chosen over Google Analytics, which would need a consent banner
  and undercut "private by default"). `persistence: memory`, proxied through the site at `/ingest`
  (Netlify rewrite) so the CSP stays `'self'` and blockers that list posthog.com don't drop counts.
  Captured: pageviews and page leave, autocapture, Download / GitHub / Discord clicks with the section
  they were in, scroll depth 25/50/75/100, demo loop completed, card clip played. The project key goes in
  `<meta name="posthog-key">`; empty means nothing loads and nothing is sent.

## Behaviour

- **Plays only when seen.** Each demo starts when it scrolls into view (IntersectionObserver) and pauses
  when it leaves or the tab is hidden; a paused demo resumes from a clean reset, never mid-flight.
- **Reduced motion.** With `prefers-reduced-motion: reduce` there is no flight and no loop: the laptop
  shows one still frame (Battery pane, Battery Health marked, the "here it is!" bubble), and the caption
  reads the three beats as one sentence.
- **Without JavaScript** the same still frame is in the HTML, so the page still tells the story.
- **Phones.** The laptop scales to the width; the headline drops to two lines of about 34 px; the
  Download button reads "Download for Mac" and a line under it says "Open this page on your Mac to
  install." Nothing is hidden on phones except the closing demo, which becomes a plain Download block.
- **Accessibility.** The demo is `aria-hidden` with a visually hidden text description of what it shows;
  every control is a real link or button; contrast meets WCAG AA (pointer orange is used for the large
  headline and graphics, never for small body text on paper).
- **Weight.** HTML + CSS + JS under 60 KB gzipped; the first screen under 300 KB including fonts (none:
  system font) and images; clips are `preload="none"`, lazy-loaded, under 1 MB each.

## The drawn mark must be real before the domain goes live

The app today flies the pointer and shows a bubble; it does not draw points, an outline or a gradient
fill around the target. The site shows that mark, so:

- The mark is added to the app as its own piece of work (its own spec in this repo, after this site).
- The site can be built and reviewed on Netlify preview URLs at any time.
- `openclicky.flowsxr.com` is pointed at the site only after an OpenClicky release that draws the mark.

## Related work, tracked separately

- **README rewrite** (this repo): lead with pointing, then dictation, matching the site's order. Ships
  with the site launch.
- **Discord.** `docs/launch/discord-setup.md` in this repo: server name, channels (#announcements,
  #general, #show-and-tell, #help, #feature-requests, #bugs, #contributors), roles, welcome message,
  rules, and an invite that never expires. Prasanth creates the server (needs his account); the invite
  goes into `netlify.toml` as `/discord`. Until it exists the Discord buttons and links are left out of
  the page rather than pointing nowhere.

## Checks before the domain goes live

- Lighthouse on the deploy preview: Performance, Accessibility, Best Practices, SEO each 95 or more.
- The demo watched in Safari and Chrome on this Mac, start to finish, twice round the loop.
- Reduced motion turned on in System Settings: the still frame shows, nothing moves.
- Screenshots at 390 px and 1440 px wide.
- Every link opened: `/download` lands on the latest release, GitHub, Discord, footer links.
- The social card renders (checked with the deploy preview URL in a link preview).
