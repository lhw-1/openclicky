# IUI demo checklist

Setup and hand checks for the Macs at the IUI demo of graduated assistance: Clicky guides by
default, and the person stays in control (esc, the pause before sending, the off-target hint, the
"not sure" reply). Written 2026-10-22 on `feat/agency-controls`.

## Why the lane matters

Guided steps (the `[NEXT]` guide, the off-target check and `[UNSURE]`) only run in the classic ask
lane (⌃⌥ or a typed request, answered by Claude with a screenshot). A Mac with its own OpenAI key
defaults to the OpenAI Realtime "fast voice" lane, which talks back faster but has no step-by-step
guide and no pause before sending. On the demo Macs, make sure the classic lane answers.

## Setup, per Mac

- [ ] Settings → Clicky: **Fast voice** off. Or sign in with a free account, which never uses Realtime.
- [ ] Settings → Privacy & Security: **Pause before sending my screen** on (the default).
- [ ] Signed in to fictional accounts only: a demo mail account, a demo user on the Mac, no real
      names, inboxes or files anywhere on screen. Close every other app and notification.
- [ ] Do Not Disturb on, so no real notification lands in a screenshot.
- [ ] Display text size and Dark Mode back to their defaults before each run (the tasks change them).
- [ ] A rehearsal of every task below on that Mac, once, before the session opens.
- [ ] `~/Library/Logs/OpenClicky/app.log` open in Console or `tail -f`, to read `ask:` and `guide:`
      lines when something looks off.

## Rehearsed tasks

1. **Make screen text larger.** Ask "how do i make the text on my screen bigger". Follow the guide
   step by step (System Settings, Displays or Accessibility, the text size control).
2. **Turn on Dark Mode.** Ask "how do i turn on dark mode". Follow the steps to Appearance.
3. **A wrong click.** During one of the guides above, click a clearly different item, well away from
   the one the pointer points at (for example a row four or more rows away in the System Settings
   sidebar). The neighbouring row can fall inside the 120-point "on target" zone and would not trigger
   the check. Clicky should say "that wasn't the spot i pointed at, let me look" and then point back.
4. **Interrupt with a new question.** While Clicky is speaking a step, hold ⌃⌥ and ask something
   else. The old answer stops at once and the new one is answered.
5. **Esc.** Ask a how-to question and press esc during the pause, while it is looking, and while it
   is speaking (one run each). Each time it stops and says "stopped".
6. **Rewrite an email draft and undo.** In the demo mail account, write a short rough draft, highlight
   it, ask "rephrase this to sound friendlier". The draft is replaced in place. Press ⌘Z to get the
   original back.

## How to check each change by hand

### 1. Esc stops at any time, and the strip stops the first step

- [ ] Hold ⌃⌥, ask a question, let go, press esc while it says "transcribing…" or "thinking…":
      nothing is answered, the pointer says "stopped", the island returns to rest.
- [ ] Press esc while the answer is being spoken: the voice stops mid-sentence.
- [ ] Ask a how-to question and click the island strip while it reads "looking at your screen"
      (before any step number shows): the question stops, no step comes back.
- [ ] During a guide, press esc while it waits for your click, and again (in another run) while it
      is fetching the next step ("step N · looking"): the guide ends, the strip goes away.
- [ ] Hold fn to dictate, press esc during the take: only the take is cancelled; an ask answer
      speaking at the same time keeps going (dictation keeps esc first).
- [ ] Ask "rephrase this" with text highlighted and press esc before the voice starts: the text is
      NOT replaced (a stopped request never acts). The log shows `ask: stopped (esc)` and no rewrite.

### 2. Pause before sending the screen

- [ ] Ask anything: for about a second the pointer and the island read "sending your screen · esc to
      cancel", then "thinking…".
- [ ] Press esc (or click the island) during that second: "stopped", and app.log has
      `ask: pausing 1.2 s` followed by `ask: stopped`, with no `ask: sending to claude` line.
- [ ] Change what is on screen during the pause (switch a window): the answer is about the new screen.
- [ ] Turn the setting off: no pause, the old timing.
- [ ] In a guide, after each click the next step comes without the pause.

### 3. Wrong-click check in guided steps

- [ ] Click exactly where the pointer points: the next step comes as before, app.log shows
      `guide: step N done (onTarget)`.
- [ ] Click the neighbouring item, well away from the pointer (more than about 120 points): the
      caption "that wasn't the spot i pointed at, let me look" shows at once, app.log shows
      `offTarget(pointsAway: …)`, and the reply checks the screen and points back if needed.
- [ ] Finish a typing step with Return or Tab: today's follow-up (`unknown` in the log).

### 4. "Not sure"

- [ ] Ask for something that is not on screen, for example "where is the export button" on an
      empty desktop. The reply says what to look for or asks what you see; the pointer does not fly,
      and the island reads "not sure · tell me what you see". app.log shows `ask: not sure what to point at`.
- [ ] Mid-guide, an unsure reply ends the guide (no "stop guide" strip); ask again with what you see.

## What could still go wrong on the day

- Esc is heard through a listen-only event tap, so the front app gets the esc too (a dialog in the
  front app may close at the same time). Rehearse with the apps you will show.
- Pointing can land 30 to 100 points off; the off-target hint only fires beyond 120, so a near miss
  on a dense list is treated as on target.
- A Debug build loses Screen Recording and Accessibility; demo with an installed, signed build.
