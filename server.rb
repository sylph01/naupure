#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Serves nowplaying.html and proxies Icecast's status-json.xsl on the same
# origin, so the page works regardless of Icecast's CORS settings.
# Stdlib only — no gems required.
#
# Optional: with the sqlite3 gem (`bundle install`), /track.json looks the
# current track up in Mixxx's library for album/BPM/key/genre/duration.
# Without the gem or the database, /track.json returns 404 and the page
# shows artist and title only.
#
#   ruby server.rb             # then open http://localhost:4567/
#
# Env: PORT (default 4567), ICECAST (default http://localhost:8000),
#      BIND (default 127.0.0.1; use 0.0.0.0 to view from another device),
#      MIXXX_DB (default ~/.mixxx/mixxxdb.sqlite)

require "socket"
require "net/http"
require "uri"
require "json"

PORT    = Integer(ENV.fetch("PORT", 4567))
BIND    = ENV.fetch("BIND", "127.0.0.1")
ICECAST = ENV.fetch("ICECAST", "http://localhost:8000")
PAGE    = File.join(__dir__, "nowplaying.html")
STATUS  = URI("#{ICECAST}/status-json.xsl")
MIXXX_DB = File.expand_path(ENV.fetch("MIXXX_DB", "~/.mixxx/mixxxdb.sqlite"))

LIBRARY_ERROR =
  begin
    require "sqlite3"
    "Mixxx library not found at #{MIXXX_DB}" unless File.file?(MIXXX_DB)
  rescue LoadError
    "sqlite3 gem not installed (run `bundle install`)"
  end

REASONS = { 200 => "OK", 400 => "Bad Request", 404 => "Not Found",
            405 => "Method Not Allowed", 502 => "Bad Gateway" }.freeze

# Duplicates of the same artist+title (e.g. FLAC/MP3/M4A copies) are resolved
# by last_played_at, which Mixxx stamps on the copy that is actually playing.
TRACK_SQL = <<~SQL
  SELECT album, bpm, key, genre, duration FROM library
  WHERE mixxx_deleted = 0 AND %<where>s
  ORDER BY last_played_at DESC NULLS LAST, id DESC
  LIMIT 1
SQL

def respond(sock, status, type, body)
  body = body.b
  sock.write "HTTP/1.1 #{status} #{REASONS.fetch(status, 'OK')}\r\n" \
             "Content-Type: #{type}\r\n" \
             "Content-Length: #{body.bytesize}\r\n" \
             "Cache-Control: no-store\r\n" \
             "Connection: close\r\n\r\n"
  sock.write body
end

def fetch_status
  res = Net::HTTP.start(STATUS.host, STATUS.port, use_ssl: STATUS.scheme == "https",
                        open_timeout: 2, read_timeout: 2) { |h| h.get(STATUS.request_uri) }
  # Icecast sometimes emits invalid UTF-8 in metadata; scrub so JSON.parse won't choke
  [res.code.to_i, res.body.to_s.force_encoding("UTF-8").scrub("?")]
rescue StandardError => e
  [502, JSON.generate(error: e.message)]
end

# Matches either separate artist/title fields (Ogg streams) or the raw
# "artist<sep>title" string Mixxx sends for MP3, built the same way in SQL so
# an artist containing the separator still matches.
def lookup_track(params)
  return [404, { error: LIBRARY_ERROR }] if LIBRARY_ERROR

  if params["q"]
    where = "coalesce(artist, '') || ? || coalesce(title, '') = ?"
    args = [params.fetch("sep", " - "), params["q"]]
  elsif params["title"]
    where = "coalesce(artist, '') = ? AND coalesce(title, '') = ?"
    args = [params.fetch("artist", ""), params["title"]]
  else
    return [400, { error: "pass q (and optional sep), or artist and title" }]
  end

  db = SQLite3::Database.new(MIXXX_DB, readonly: true)
  db.busy_timeout = 1000
  row = db.get_first_row(format(TRACK_SQL, where: where), args)
  return [200, { found: false }] unless row

  album, bpm, key, genre, duration = row
  [200, { found: true,
          album: album.to_s.empty? ? nil : album,
          bpm: bpm.to_f.positive? ? bpm.to_f.round(2) : nil,
          key: key.to_s.empty? ? nil : key,
          genre: genre.to_s.empty? ? nil : genre,
          duration: duration.to_f.positive? ? duration.to_f.round(2) : nil }]
rescue StandardError => e
  [502, { error: e.message }]
ensure
  db&.close
end

def handle(sock)
  request_line = sock.gets or return
  method, target, = request_line.split(" ", 3)
  # drain headers
  while (line = sock.gets) && line != "\r\n"; end

  return respond(sock, 405, "text/plain", "GET only\n") unless method == "GET"

  uri = URI(target)
  case uri.path
  when "/", "/index.html", "/nowplaying.html"
    respond(sock, 200, "text/html; charset=utf-8", File.read(PAGE))
  when "/status-json.xsl"
    code, body = fetch_status
    respond(sock, code, "application/json; charset=utf-8", body)
  when "/track.json"
    code, data = lookup_track(URI.decode_www_form(uri.query.to_s).to_h)
    respond(sock, code, "application/json; charset=utf-8", JSON.generate(data))
  else
    respond(sock, 404, "text/plain", "Not found\n")
  end
rescue StandardError => e
  warn "request error: #{e.class}: #{e.message}"
ensure
  sock.close unless sock.closed?
end

$stdout.sync = true
server = TCPServer.new(BIND, PORT)
trap("INT")  { exit }
trap("TERM") { exit }
puts "Now Playing → http://#{BIND == '0.0.0.0' ? 'localhost' : BIND}:#{PORT}/  (Icecast: #{ICECAST})"
puts LIBRARY_ERROR ? "Track details off: #{LIBRARY_ERROR}" : "Track details from #{MIXXX_DB}"

loop do
  client = server.accept
  Thread.new(client) { |c| handle(c) }
end
