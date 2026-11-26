# Name and logo

The source code is GPL-3.0-or-later and you may fork it. The name **Charland**, the Charland logo and app icon, and the
name **Char Studio** are not licensed under the GPL.

- You may say that your project is "based on Charland" or "a fork of Charland".
- If you distribute a modified build, please call it something else, use another icon, and change the bundle id
  (`CHARLAND_BUNDLE_ID` in `Config/Identita.xcconfig`, or `Config/Local.xcconfig`), so that people do not mistake it for the
  official app and so that it does not collide with an installed official copy.
- Do not make your build check the official update feed, and point its bug report and idea forms
  (`SupportLinks` in `Sources/Charland/Settings/SupportPane.swift`) at your own address.
- Unmodified builds you compile yourself for your own use need nothing.


## Third-party artwork in the app

The orange Claude agent mascot (`Sources/Charland/Agents/ClaudeMascot.swift`) is redrawn after the mascot that Claude Code
prints in the terminal. That artwork belongs to Anthropic. It is **not** licensed under the GPL, it is not part of what
this project grants you, and it will be replaced or removed if the rights holder asks. The other agent mascots and the
rest of the artwork in this repository are original to Charland, except where `THIRD_PARTY_LICENSES.md` says otherwise.
Charland does not ship the logos of Anthropic, OpenAI or other AI companies; everyone can set their own symbol in
Settings > Dock.

Questions: open an issue.
