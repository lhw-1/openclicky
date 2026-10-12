# Settings revamp: find things where you'd look for them

2026-10-12. The settings grew one feature at a time, and each new row went wherever it fit. Someone
who wants to change Clicky's voice opens Settings and finds no "Voice" anywhere. It sits halfway
down "Clicky", under a section called Voice whose first row is about which AI answers. This page
takes stock of everything and redraws the map around what people come looking for.

## What we have (inventory, 2026-10-12)

About 75 catalog rows on 8 pages, plus 2 pages of their own ("Your words", "How it writes") and
controls in the island, the menu bar and the tour.

The problems, roughly in order of how often someone would hit them:

1. **Voice is buried.** The voice picker, Kokoro, the Mac voice, fast voice and hands-free all
   sit under Clicky, after the pointer.
2. **Language is split three ways.**
   - The dictation language is on "How it writes" › Styles.
   - Clicky's language is on Clicky › Voice.
   - The script is on "How it writes".
   - The Dictation page has only a footnote pointing at Styles.
3. **Keys live under "Account"**, but the account is optional. Many rows say "add a key under
   Account", which reads like "sign up". Keys and the Claude/ChatGPT plans are their own thing:
   how the AI gets paid for.
4. **The dictation key is on Keyboard**, not on Dictation.
5. **"Model" (Sonnet/Opus) sits under Agent**, but it picks who answers questions.
6. **Updates are hidden in About.**
7. **Sounds and haptics (dictation tones) are on The Orb.**
8. **Indian options are everywhere for everyone**: the Sarvam engine, the Sarvam voice, the Sarvam
   key, the Sarvam usage row (shown even with no key), 10 of 11 dictation languages, 7 Clicky
   languages, and "Script for Indian languages".
9. **Search covers only the catalog.** Dictionary, snippets, styles and history can't be found by
   search.

## The map

The pages follow how a person thinks: what OpenClicky is (General), the two things it does
(Dictation, Clicky) and how Clicky sounds (Voice), what you've said and how it's written (your
two pages), then what it looks like, the keys you press, the AI keys you pay with, your account,
privacy and about.

| # | Page | Sections (← where a row came from) |
|---|------|------------------------------------|
| 1 | General | **Region** (new) · Appearance, where OpenClicky lives, menu bar · Startup · Motion · **Updates** ← About |
| 2 | Dictation | **Key** ← Keyboard (key, where it is, the fn rows) · Who hears you (engines, Parakeet) · **Language** ← How it writes (language, script) · **Clean-up** ← How it writes · Microphone · Takes (quiet timeout, **paste last take** ← Keyboard) · **Sounds** ← The Orb (sounds, haptics) |
| 3 | Clicky | **Answers** (answers come from, **Claude model** ← Agent) · Pointer · Agent (mode, workspace) |
| 4 | **Voice** (new) | Language (Clicky speaks and listens in) · Voice (picker, Kokoro, Mac voice, more voices) · Fast voice and hands-free |
| 5 | Your words | (unchanged) |
| 6 | How it writes | Dictionary, snippets, styles. A footnote says language and clean-up moved to Dictation |
| 7 | The Orb | Show, look, when it appears, tooltips |
| 8 | **Shortcuts** (was Keyboard) | Every key at a glance; the dictation key row links to Dictation to change it; hands-free only when it can work |
| 9 | **Keys & Plans** (new) | Your keys, where keys go · Subscriptions (Claude Code, Codex) ← Account |
| 10 | Account | Sign in, allowance and usage (the Sarvam row only with a Sarvam key), backend |
| 11 | Privacy & Security | (unchanged) |
| 12 | About | Version, help |

Every "add a key under Account" becomes "under Keys & Plans", and those buttons open that page.
The island's key warning opens it too.

Search gains rows for Dictionary, Snippets, Styles and Your takes, each with a button that opens
the page.

## India or rest of the world

General › Region: **India** or **Rest of the world**. Until it's set, it follows the Mac: India
when the Mac's region is India or the time zone is Asia/Kolkata. Choosing one only changes what's
offered, never what's set: an option that is already in use always stays visible.

Rest of the world hides:
- the Sarvam engine
- Sarvam in the "Add a key" list
- Sarvam in "More voices"
- the Indian dictation languages and the Indian Clicky languages
- the script row

It also offers the languages a world user needs instead: English (US), English (UK), Español,
Français, Deutsch, Italiano, Português.

India keeps everything, and the script row shows only while the language is auto-detect or
Indian.

## Not in this round

- Island and menu bar duplicates (dock, agent mode, replay tour). They're shortcuts to the same
  setting, which is fine.
- A per-style language.
- Asking for the region in the welcome tour.
