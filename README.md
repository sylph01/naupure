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

Environment variables:

| Var | Default | |
|---|---|---|
| `PORT` | `4567` | port for the page |
| `ICECAST` | `http://localhost:8000` | Icecast base URL |
| `BIND` | `127.0.0.1` | listen address |

Page query parameters:

| Param | |
|---|---|
| `mount` | pick a mount by `listenurl` suffix, e.g. `?mount=/mixxx` |
| `interval` | poll interval in ms (min 500, default 2000) |
| `sep` | artist/title separator (default `" - "`) |
| `src` | status JSON URL to poll instead of the default |
| `transparent=1` | transparent background (e.g. OBS browser source) |
| `minimal=1` | hide the meta row (listeners, mount, elapsed time) |

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
