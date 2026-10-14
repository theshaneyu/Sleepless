# AGENTS.md

## Reading Sleepless's logs

Sleepless logs through `os.Logger` (the `Log` enum in `App.swift`) under the subsystem
`com.aboudjem.Sleepless`. Nothing is written to a log file of its own: logd keeps and rotates
these entries, so `log show` is the only way to read them.

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "com.aboudjem.Sleepless"'
```

Narrow it with a category:

| Category         | What it logs                                                        |
| ---------------- | ------------------------------------------------------------------- |
| `wifi`           | Wi-Fi dropping, rejoining, failed rejoins, phone-dashboard switches |
| `remote-control` | `claude remote-control` servers that fail to start or exit          |
| `dashboard`      | Apps quit from the phone dashboard                                  |
| `app`            | Everything else: the local CLI, login item, `sudo` and other launches |

```sh
/usr/bin/log show --last 1h --style compact \
  --predicate 'subsystem == "com.aboudjem.Sleepless" AND category == "wifi"'
```

Things to know:

- Call `/usr/bin/log` by its full path. In zsh, plain `log` is a shell builtin and fails with
  `too many arguments`.
- In Claude Code, run `log show` with the sandbox disabled. Inside the sandbox it prints only the
  header line, with no entries.
- Sleepless logs events only (a drop, a rejoin, a failure), never its 5-second Wi-Fi checks. An
  empty result for a quiet period is normal.
- Values in messages (network names, repo names) are marked public. Logs from builds before the
  switch to `os.Logger` show them as `<private>`.
- To see what macOS itself did with Wi-Fi at the same time, query `process == "airportd"`. Its
  network names are redacted, so match networks by the numeric ID in `ssid=<redacted> (…)`.
