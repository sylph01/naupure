#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Serves nowplaying.html and proxies Icecast's status-json.xsl on the same
# origin, so the page works regardless of Icecast's CORS settings.
# Stdlib only — no gems required.
#
#   ruby server.rb             # then open http://localhost:4567/
#
# Env: PORT (default 4567), ICECAST (default http://localhost:8000),
#      BIND (default 127.0.0.1; use 0.0.0.0 to view from another device)

require "socket"
require "net/http"
require "uri"
require "json"

PORT    = Integer(ENV.fetch("PORT", 4567))
BIND    = ENV.fetch("BIND", "127.0.0.1")
ICECAST = ENV.fetch("ICECAST", "http://localhost:8000")
PAGE    = File.join(__dir__, "nowplaying.html")
STATUS  = URI("#{ICECAST}/status-json.xsl")

REASONS = { 200 => "OK", 404 => "Not Found", 405 => "Method Not Allowed",
            502 => "Bad Gateway" }.freeze

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

def handle(sock)
  request_line = sock.gets or return
  method, target, = request_line.split(" ", 3)
  # drain headers
  while (line = sock.gets) && line != "\r\n"; end

  return respond(sock, 405, "text/plain", "GET only\n") unless method == "GET"

  case URI(target).path
  when "/", "/index.html", "/nowplaying.html"
    respond(sock, 200, "text/html; charset=utf-8", File.read(PAGE))
  when "/status-json.xsl"
    code, body = fetch_status
    respond(sock, code, "application/json; charset=utf-8", body)
  else
    respond(sock, 404, "text/plain", "Not found\n")
  end
rescue StandardError => e
  warn "request error: #{e.class}: #{e.message}"
ensure
  sock.close unless sock.closed?
end

server = TCPServer.new(BIND, PORT)
trap("INT")  { exit }
trap("TERM") { exit }
puts "Now Playing → http://#{BIND == '0.0.0.0' ? 'localhost' : BIND}:#{PORT}/  (Icecast: #{ICECAST})"

loop do
  client = server.accept
  Thread.new(client) { |c| handle(c) }
end
