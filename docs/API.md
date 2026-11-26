# The Charland API

Any app, script or Shortcut can show an activity in the island. The rules are those of Apple's Live Activities: same
names, 8 hours at most, messages of 4 KB at most.

If Charland is not running the commands do nothing and exit with 0: a script never fails because the island is missing.

## From the terminal

The command lives inside the app. To have it everywhere:

```bash
sudo ln -sf "/Applications/Charland.app/Contents/Helpers/charland" /usr/local/bin/charland
```

Three lines for a build:

```bash
charland post --id build --title "Build" --progress 0.1 --symbol hammer.fill
```

```bash
charland update --id build --title "Build" --progress 0.8 --status "Linking"
```

```bash
charland end --id build
```

Or a single line that follows the command and reads percentages and counters such as `[12/340]` by itself:

```bash
charland watch --title "Build" -- npm run build
```

A five minute countdown:

```bash
charland post --id pizza --title "Pizza" --ends-in 300 --tint orange
```

## Long commands, automatically

Add to `~/.zshrc`:

```bash
eval "$(charland shell-init zsh)"
```

Every command that runs longer than 10 seconds shows up in the island, and a tap on the trackpad tells you when it ends.

## From Shortcuts

Two actions: **Show in the island** (name, title, progress 0 to 100, status, symbol) and **Close in the island** (name).

## From another app, in Swift

The `CharlandKit` package (`Packages/CharlandKit`) has no dependencies.

```swift
import CharlandKit

let client = CharlandClient()
try client.connect()                      // fails right away if Charland is not running
var m = ActivityMessage(op: .upsert, client: "backup", id: "night")
m.template = .progress
m.title = "Backup"
m.progress = 0.4
try client.send(m)
```

The first time a new client sends an activity, Charland asks for permission in the island.

## The socket

`~/Library/Application Support/Charland/api.sock`, open to your user only (mode 0600, folder 0700). One line of JSON
per message, one line of reply.

```json
{"v":1,"op":"upsert","client":"build","id":"b1","template":"progress","title":"Build","progress":0.5}
```

| Field | Meaning |
|---|---|
| `v` | version, always 1 |
| `op` | `upsert`, `end`, `hello`, `list` |
| `client` | who sends: the name the user recognizes |
| `id` | activity identifier, unique per client |
| `template` | `progress`, `countdown`, `status`, `approval`, `custom` |
| `title`, `subtitle`, `status` | short texts |
| `symbol` | an SF Symbol name |
| `tint` | white, blue, green, orange, red, yellow, purple, pink, teal, gray |
| `progress` | 0 to 1 |
| `endsAt`, `startedAt` | seconds since 1970 |
| `command`, `detail` | for `approval`: the exact command and an explanation |
| `slots` | for `custom`: `leading`, `trailing`, `minimal`, `center`, `bottom`, each with `symbol`, `text` or `progress` |
| `actions` | at most two, each with `id` and `title` |
| `alert` | `expand`, `haptic` (`done`, `waiting`, `error`), `sound` |
| `priority` | -1 to 2 |
| `ttl` | seconds after which it closes by itself, 8 hours at most |
| `origin` | the app that hosts the sender, to jump to the right window |

Four `status` values have a fixed badge and text: `working`, `waiting`, `done`, `error`.

When the user taps an action, this arrives on the same channel:

```json
{"event":"action","id":"b1","action":"stop"}
```

No HTML and no address opened without permission: an activity is made only of text, symbols and numbers.

## Not done yet

The local HTTP address with a token and the `charland://` address are in the spec but not written yet.
