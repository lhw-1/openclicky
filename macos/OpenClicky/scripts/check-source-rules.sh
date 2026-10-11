#!/usr/bin/env bash
# Rules about the Swift source itself, checked from the shell rather than from OpenClickyTests.
# The test host is the app; when a test reads files under ~/Documents, macOS asks the person for
# Documents access on every unsigned build, so source checks live here instead.
# Run: npm run lint:source (or bash macos/OpenClicky/scripts/check-source-rules.sh)
set -euo pipefail

source_root="$(cd "$(dirname "$0")/../OpenClicky" && pwd)"
failures=0

fail() {
  echo "✗ $1"
  failures=$((failures + 1))
}

source_file() {
  local found
  found="$(find "$source_root" -name "$1" -print -quit)"
  if [[ -z "$found" ]]; then
    fail "$1 not found; update check-source-rules.sh"
    return 1
  fi
  echo "$found"
}

# The account UI has no password fields left (codes, not passwords). SettingsAccountPage keeps a
# SecureField for own API keys.
for name in AccountSheet.swift EmailAccountForm.swift BillingStatus.swift SettingsAccountPage.swift; do
  file="$(source_file "$name")" || continue
  if [[ "$name" != SettingsAccountPage.swift ]] && grep -q 'SecureField' "$file"; then
    fail "$name still has a password field"
  fi
  if grep -qi 'forgot password' "$file"; then fail "$name still offers a password reset"; fi
  if grep -q 'isSecure: true' "$file"; then fail "$name still has a secure credential field"; fi
done

# Every engine that records a take or a question selects the chosen microphone (F-13, F-21).
for name in BuddyDictationManager.swift RealtimeVoiceClient.swift; do
  file="$(source_file "$name")" || continue
  grep -q 'AVAudioEngine()' "$file" || fail "$name no longer owns an engine; update this rule"
  grep -q 'MicrophoneDevices.apply(preferredUID:' "$file" || fail "$name records without the chosen microphone"
done

# A print that reports a failure sits next to an AppLog.append, so it reaches the log the person
# can send (F-37). The print stays for the smoke runs.
for name in BuddyDictationManager.swift AppleSpeechTranscriptionProvider.swift \
            OpenAIAudioTranscriptionProvider.swift AssemblyAIStreamingTranscriptionProvider.swift; do
  file="$(source_file "$name")" || continue
  grep -q 'AppLog.append(' "$file" || fail "$name never writes to the app log"
  while IFS= read -r problem; do
    [[ -n "$problem" ]] && fail "$name:$problem reports a failure with print only"
  done < <(awk '
    { lines[NR] = $0 }
    END {
      for (n = 1; n <= NR; n++) {
        line = tolower(lines[n])
        if (index(line, "print(") == 0) continue
        if (line !~ /❌|⚠️|failed|error|denied|unavailable|silent/) continue
        if (index(lines[n-1], "AppLog.append(") || index(lines[n], "AppLog.append(") || index(lines[n+1], "AppLog.append(")) continue
        print n
      }
    }' "$file")
done

if (( failures > 0 )); then
  echo "$failures source rule(s) broken"
  exit 1
fi
echo "source rules hold"
