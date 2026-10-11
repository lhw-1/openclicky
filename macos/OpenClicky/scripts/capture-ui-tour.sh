#!/usr/bin/env bash
# Captures every screen of a Debug build for a design review.
#
#   scripts/capture-ui-tour.sh <path/to/OpenClicky.app> <output-dir>
#
# Launches the app with --openclicky-ui-tour (UITour.swift, Debug builds only), which steps through
# the window's pages, the onboarding, the island's placements and states, the menu bar panel and
# the orb, announcing each shot by window number. Each window is captured on its own
# (`screencapture -l`), so nothing else on the desktop lands in the pictures. The app runs under a
# throwaway home (CFFIXED_USER_HOME): signed out, no real history, made-up demo takes instead, so
# the shots can be shared. Quit any running OpenClicky first: two copies fight over the shortcuts
# and the island.
set -euo pipefail

app="${1:?usage: capture-ui-tour.sh <OpenClicky.app> <output-dir>}"
out="${2:?usage: capture-ui-tour.sh <OpenClicky.app> <output-dir>}"
mkdir -p "$out"
log="$out/tour.log"
rm -f "$log"

demo_home=$(mktemp -d -t openclicky-tour-home)
CFFIXED_USER_HOME="$demo_home" "$app/Contents/MacOS/OpenClicky" --openclicky-ui-tour "$log" >"$out/app-stdout.log" 2>&1 &
app_pid=$!
trap 'kill $app_pid 2>/dev/null || true; rm -rf "$demo_home"' EXIT

seen=0
for _ in $(seq 1 1800); do
  if [[ -f "$log" ]]; then
    total=$(wc -l <"$log" | tr -d ' ')
    while (( seen < total )); do
      seen=$((seen + 1))
      line=$(sed -n "${seen}p" "$log")
      case "$line" in
        SHOT\ *)
          read -r _ name window <<<"$line"
          screencapture -x -o -l "$window" "$out/$name.png" && echo "captured $name"
          ;;
        MISSING\ *) echo "no window for ${line#MISSING }" ;;
        DONE) echo "tour finished"; exit 0 ;;
      esac
    done
  fi
  if ! kill -0 "$app_pid" 2>/dev/null; then echo "the app exited before the tour finished" >&2; exit 1; fi
  sleep 0.2
done
echo "timed out" >&2
exit 1
