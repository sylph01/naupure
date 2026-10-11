# naupure

A small web page that shows the track currently playing in [Mixxx](https://mixxx.org/).
It is meant to run locally, on a separate screen next to Mixxx.

Mixxx sends now-playing metadata to a local Icecast server through Live
Broadcasting. A small Ruby server serves the page and proxies Icecast's
`status-json.xsl`, and the page polls it. The track switches when Mixxx decides
it does, which is when the crossfader passes the middle.

```
Mixxx --(Live Broadcasting)--> Icecast :8000 <--(proxy)-- server.rb :4567 <--(poll)-- nowplaying.html
```

## Requirements

- Mixxx with Live Broadcasting
- Icecast 2 (tested with 2.5.0 from Ubuntu 26.04 `apt`)
- Ruby (standard library only, no gems)
- Optional: Bundler and the `sqlite3` gem, to show album and BPM from your Mixxx library

## Setup

### 1. Install Icecast

```sh
sudo apt install icecast2
```

When the installer asks whether to configure Icecast2, answer yes. Keep the
hostname `localhost` and set the source, relay and admin passwords. You can
redo this later with `sudo dpkg-reconfigure icecast2`.

### 2. Add a mount for Mixxx

Edit the config (`sudoedit /etc/icecast2/icecast.xml`) and add this inside
`<icecast>`:

```xml
<mount type="normal">
    <mount-name>/mixxx</mount-name>
    <charset>UTF-8</charset>
    <authentication>
        <role type="static" allow-method="source,put,get" deny-web="*" allow-admin="metadata">
            <option name="username" value="mixxx" />
            <option name="password" value="CHANGE_ME" />
        </role>
        <role type="anonymous" allow-method="get" allow-web="*" allow-admin="metadata" />
    </authentication>
</mount>
```

Why each part is needed on Icecast 2.5:

- **`static` role**: the account Mixxx uses to stream to `/mixxx`.
- **`anonymous` role with `allow-admin="metadata"`**: Mixxx (libshout 2.4)
  sends its title updates (`GET /admin/metadata`) without credentials that
  Icecast 2.5 recognizes. Without this role every title update fails with 401,
  even though the audio stream works. Anonymous clients can only update
  metadata and listen; they cannot push audio. This is fine for a local-only
  setup.
- **`<charset>UTF-8</charset>`**: otherwise Icecast assumes ISO-8859-1 for MP3
  metadata, which breaks non-Latin titles.

Then start Icecast and enable it at boot:

```sh
sudo systemctl enable --now icecast2
sudo systemctl restart icecast2   # after any later config change
```

Check that it is up with `curl -s http://localhost:8000/status-json.xsl`.

### 3. Configure Mixxx

In Preferences → Live Broadcasting, add a connection:

| Setting | Value |
|---|---|
| Type | Icecast 2 |
| Host / Port | `localhost` / `8000` |
| Mount | `/mixxx` |
| Login / Password | `mixxx` / the password from the `<mount>` block |
| Format | MP3 |
| Use UTF-8 encoding for metadata | **on** (otherwise Japanese and other non-Latin text becomes `?`) |

Then turn on Live Broadcasting. Metadata only flows while broadcasting is on,
even if nobody is listening.

## Running

```sh
ruby server.rb
```

Open <http://localhost:4567/>.

### Optional: album and BPM from the Mixxx library

```sh
bundle install
```

This installs the `sqlite3` gem from the `Gemfile` (prebuilt, no compiler
needed). `ruby server.rb` then picks it up; `bundle exec ruby server.rb` also
works. `sudo apt install ruby-sqlite3` is an alternative to Bundler.

With the `sqlite3` gem installed, `server.rb` looks the current track up in
Mixxx's library (`~/.mixxx/mixxxdb.sqlite`, opened read-only) and the page
shows album and BPM under the artist. On startup it prints either
`Track details from ...` or the reason details are off. Without the gem or the
database, the page shows artist and title only.

The lookup is also available as JSON:

```sh
curl -s "http://localhost:4567/track.json?q=lapix%20feat.%20DJ%E5%8B%9D%E4%B9%9F%20-%20kokoro"
```

```json
{"found":true,"album":"RAVE TAISEN COMPILATION ALBUM 2nd","bpm":85.5,"key":"Db","genre":null,"duration":427.44}
```

- `q` is the raw now-playing string from Icecast (`sep` sets the separator,
  default `" - "`). For Ogg streams with separate fields, pass `artist` and
  `title` instead.
- `bpm`, `key`, `genre` and `album` are `null` when empty. BPM and key are
  filled in only after Mixxx analyzes the track. `duration` is in seconds.
- If several library entries match (e.g. FLAC/MP3/M4A copies of one track),
  the one Mixxx most recently played wins.

Environment variables:

| Var | Default | |
|---|---|---|
| `PORT` | `4567` | port for the page |
| `ICECAST` | `http://localhost:8000` | Icecast base URL |
| `BIND` | `127.0.0.1` | listen address |
| `MIXXX_DB` | `~/.mixxx/mixxxdb.sqlite` | Mixxx library for the optional lookup |

Page query parameters:

| Param | |
|---|---|
| `mount` | pick a mount by `listenurl` suffix, e.g. `?mount=/mixxx` |
| `interval` | poll interval in ms (min 500, default 2000) |
| `sep` | artist/title separator (default `" - "`) |
| `src` | status JSON URL to poll instead of the default |
| `transparent=1` | transparent background (e.g. OBS browser source) |
| `minimal=1` | hide the meta row (listeners, mount, elapsed time) |
| `details=0` | don't look up or show album/BPM |

## Troubleshooting

Logs are in `/var/log/icecast2/` (`access.log`, `error.log`).

| Symptom | Cause |
|---|---|
| `"metadata": null` and `GET /admin/metadata ... 401` from `libshout` in `access.log` | The anonymous metadata role is missing from the mount |
| `Admin command "metadata" on non-existent source` | Mixxx isn't connected; turn broadcasting back on |
| Non-Latin characters show as `?` | Mixxx's "Use UTF-8 encoding for metadata" is off |
| Garbled characters (like `ã\x83...`) | `<charset>UTF-8</charset>` is missing from the mount |
| Page says "Can't reach Icecast" | Icecast isn't running, or `ICECAST` points to the wrong place |

To test without Mixxx (while some source is connected to `/mixxx`):

```sh
curl -u mixxx "http://localhost:8000/admin/metadata?mount=/mixxx&mode=updinfo&charset=UTF-8&song=Artist%20-%20Title"
```

See [design-docs/HANDOFF.md](design-docs/HANDOFF.md) for design notes.
