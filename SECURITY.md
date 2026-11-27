# Security

Charland asks for powerful permissions (Accessibility, Microphone, Calendar, Input Monitoring) and installs a small
privileged helper for the closed-lid keep-awake feature, so security reports are taken seriously.

## Reporting a vulnerability

Please do **not** open a public issue. Use GitHub's private reporting: the **Security** tab of this repository, then
**Report a vulnerability**. Include the macOS version, the Charland version, and steps to reproduce.

You can expect an answer within a few days. Fixes ship in a new release and the report is credited unless you prefer
otherwise.

## What is in scope

- The privileged helper (`Sources/CharlandHelper`) and how it checks who talks to it.
- The local API socket (`~/Library/Application Support/Charland/api.sock`) and the `charland` command.
- Anything that lets one app act on another through Charland without the user's approval.
- Handling of the user's clipboard history, dictation text and audio.

Dictation audio is processed on the device. Network use, in full:
- speech model download at first use (Hugging Face, GitHub releases of k2-fsa);
- weather: MET Norway (api.met.no) gets a location rounded to about a kilometre; Apple's MapKit gets the exact
  location for reverse geocoding and whatever you type in the city search;
- synced lyrics from lrclib.net (and lrc.red when lrclib.net has no word timings) and album artwork lookups on itunes.apple.com for the "Now Playing" features;
- update checks in official builds only (charland.charstudio.app);
- the Charcal agenda and the "Report a bug" / "Suggest a feature" forms, which talk to Char Studio's server
  (charcal.charstudio.app; a form sends what you type, the app version, build and language, plus macOS version and Mac
  model unless you switch that off, and your email if you give one). Forks send to the same
  server unless they change `SupportPane.swift` and the Charcal client.

- the Dock usage widget runs your own installed `claude` and `codex` commands, which talk to Anthropic and OpenAI.

Please report anything else that leaves the Mac.
