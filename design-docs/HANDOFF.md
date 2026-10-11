# Mixxx Now Playing — Handoff

A small web page that shows the track currently playing in Mixxx. Metadata is
read from a local Icecast server that Mixxx broadcasts to.

## Background / why this approach

Mixxx has no general-purpose API (HTTP/WebSocket/OSC) for now-playing metadata.
Options considered:

1. **Poll `mixxxdb.sqlite` history**: works, but a track only lands in history
   after Mixxx counts it as "played", so it lags.
2. **Read the Mixxx window title**: crossfader-accurate, but scraping and awkward
   on Wayland.
3. **Local Icecast as a metadata tap** ← chosen. Mixxx's Live Broadcasting sends
   metadata to Icecast. We poll Icecast's `status-json.xsl`. This uses Mixxx's
   own "now playing" decision, which switches when the crossfader passes the
   middle.

An MPRIS / file-output feature was attempted in a 2018 GSoC PR (mixxxdj/mixxx#1675)
but, as far as we know, it never shipped. Check your build if MPRIS matters.

## Files

| File | Role |
|---|---|
| `nowplaying.html` | Self-contained page (HTML + CSS + JS). Polls status JSON, parses, renders. |
| `server.rb` | Ruby server (`socket` + `net/http`). Serves the page at `/` and proxies `/status-json.xsl` → Icecast, so CORS is a non-issue. Optional `/track.json` library lookup needs the `sqlite3` gem (`Gemfile`, `bundle install`); everything else is stdlib only. |

## Running

```sh
ruby server.rb                       # http://localhost:4567/
PORT=8080 ICECAST=http://localhost:8000 BIND=0.0.0.0 ruby server.rb
```

Env vars: `PORT` (4567), `ICECAST` (http://localhost:8000), `BIND` (127.0.0.1).

Full setup (Icecast install, mount config, Mixxx settings) is in the
[README](../README.md). In short:
- Icecast running locally on :8000 with a `/mixxx` mount that has
  `<charset>UTF-8</charset>`, a `static` source role for Mixxx, and an
  `anonymous` role allowed `metadata` admin (see "Icecast 2.5 notes" below).
- Mixxx → Preferences → Live Broadcasting: Icecast 2, `localhost:8000`, mount
  `/mixxx`, login `mixxx`, MP3, "Use UTF-8 encoding for metadata" on.
  Broadcasting enabled.

## Icecast 2.5 notes

Ubuntu 26.04's `apt` ships Icecast **2.5.0**, which changed two things this
project depends on:

- **Metadata auth.** 2.5 uses role/ACL auth. With only the global
  `<source-password>`, Mixxx logs in as role `legacy-global-source`, which can
  stream but not call `/admin/metadata`. libshout 2.4.6 (used by Mixxx) also
  sends its metadata request without credentials that 2.5 recognizes:
  `access.log` shows the username as `-` and returns 401, while `curl -u` with
  the same credentials gets 200. A per-mount `anonymous` role with
  `allow-admin="metadata"` fixes it. `error.log` still logs "Got legacy
  SOURCE-style metadata update command" on each update; that is harmless.
- **JSON layout.** The title is no longer `source.title`. For MP3 it is
  `source.metadata.x_icy_title`. `metadata` is `null` until the first update.

## Page behavior (`nowplaying.html`)

- Status source: `?src=` if given. Otherwise `/status-json.xsl` when served over
  http(s), or `http://localhost:8000/status-json.xsl` when opened as `file://`
  (this works only if Icecast sends CORS headers).
- `icestats.source` may be an object (one mount) or an array (several). The page
  normalizes it. Selection order: `?mount=` match on `listenurl` suffix → first
  source with `title`/`artist` → first source.
- Fields: `fields()` reads `artist`/`title` from the top of the source (Icecast
  2.4) or from `metadata.artist` / `metadata.title` / `metadata.x_icy_title`
  (Icecast 2.5).
- Parsing: uses the `artist` field if present. Otherwise splits `title` on
  the first `SEP` (default `" - "`, matching Mixxx's default `$artist - $title`
  metadata format). It splits before trimming, because a track with no artist
  tag arrives as `" - Title"`.
- Details: on each track change it calls `/track.json` (raw `q` + `sep`, or
  `artist`/`title` when Icecast has separate fields) and shows album and BPM
  in `#details`. Stale responses for an earlier track are dropped. A 404 turns
  the lookup off for the session. `?details=0` disables it.
- Re-renders only when artist+title changes (fade transition). Shows elapsed
  time since the change, listener count, and mount path.
- Polls every `INTERVAL` ms via chained `setTimeout`, so requests never overlap.

Query params: `src`, `mount`, `interval` (ms, min 500, default 2000), `sep`,
`transparent=1` (for OBS browser source), `minimal=1` (hide meta row).

## Server behavior (`server.rb`)

- One thread per connection, `Connection: close`, GET only.
- Routes: `/`, `/index.html`, `/nowplaying.html` → page (re-read from disk on
  every request, so edits show up on reload); `/status-json.xsl` → proxied;
  `/track.json` → library lookup. Anything else → 404.
- `/track.json`: `require "sqlite3"` is attempted at startup. If the gem or
  `MIXXX_DB` is missing, it returns 404 `{"error": ...}`. Otherwise it opens
  the DB read-only per request and matches
  `coalesce(artist,'') || sep || coalesce(title,'') = q` against `library`
  (`mixxx_deleted = 0`), building the string the way Mixxx's `$artist - $title`
  template does. No split is needed, and `" - Title"` (no artist) matches.
  Ties go to `last_played_at DESC NULLS LAST`. Duplicates are FLAC→MP3/M4A
  conversions of one track, and Mixxx stamps `last_played_at` on the copy
  actually playing. Returns album, bpm, key, genre, duration (`null` when
  empty; bpm 0 means not analyzed).
- Upstream timeouts are 2s. Failure → `502` with `{"error": "..."}`, which the
  page shows as "Can't reach Icecast".
- The body is force-encoded to UTF-8 and scrubbed, because Icecast can emit
  invalid UTF-8 in metadata.

## Verified so far

- `ruby -c server.rb` and `node --check` on the page script both pass.
- End-to-end against a fake Icecast (stdlib TCPServer on :18000) with a JSON
  payload containing Japanese metadata: proxy passes it through intact, page
  route returns 200, unknown route returns 404, Icecast down returns 502 with
  JSON error.
- Real run on 2026-10-11: Mixxx (libshout 2.4.6) → Icecast 2.5.0 (Ubuntu
  26.04 `apt`) → `server.rb` → page in a browser. Track changes from Mixxx
  show up on the page, including Japanese artist/title (with Mixxx's UTF-8
  metadata option on) and tracks with no artist tag.
- **Not yet tested:** the fade transition and elapsed timer under real use,
  and OBS transparency.

## Known limits / things to watch

- Metadata only flows while Mixxx is actively broadcasting. You need an encoder
  running even if nobody listens. When Mixxx reconnects, the new source starts
  with `metadata: null` until the next track change.
- Non-Latin text becomes literal `?` if Mixxx's "Use UTF-8 encoding for
  metadata" is off. Mixxx does that conversion, not Icecast.
- The anonymous metadata role means any local process can set the title. That
  is fine because this is used only locally, beside Mixxx on a second screen.
- For Ogg Vorbis streams, Mixxx's "dynamically update Ogg metadata" option may
  be needed. MP3 updates normally.
- The split on `SEP` uses the first occurrence. An artist name containing
  `" - "` would split wrong. Pick a rarer separator in Mixxx's custom metadata
  format and pass it via `?sep=` if that matters.
- Album/BPM/key/genre/duration come from the optional library lookup.
  Displayed: album and BPM only (key, genre, duration are in the JSON). Most
  tracks have no BPM/key until Mixxx analyzes them, which is expected.
  Artwork is out of scope; most tracks have none.
- If tags are edited in Mixxx while a track plays, the Icecast string and the
  DB may disagree briefly; the lookup returns `found: false` and the page
  shows artist/title only.

## Possible next steps

- Tune the visuals for a second-screen display next to Mixxx (OBS is
  secondary).
- Optional: Server-Sent Events from `server.rb` instead of client polling.
- Optional: a set history list (last N tracks) on the page.
