extends RefCounted
## Whether the headset may use a server address: the headset's half of DIDSA-CAD's pairing checks
## (DIDSA-CAD client/lib/vr_pairing/headset_pairing.dart, `checkAddress`, and docs/vr-headset-pairing.md). Used for a typed server (L4) and for a
## scanned one (L6): the same rules, so a code cannot get an address in that a person could not type.
##
## Refused: not http(s), no host, localhost (the headset is not the server), 10.0.2.2 (the Android emulator's alias), link-local addresses, and plain
## http:// to anything that is not on a local network. Warned (allowed): http:// on a local network (the key travels unencrypted), a .local name
## (may not resolve), a Tailscale address (same tailnet needed), https:// to a private address (the certificate must be trusted).

enum Level { OK, WARN, REFUSED }

const SCHEME_HTTP := "http"
const SCHEME_HTTPS := "https"


static func normalise(raw_url: String) -> String:
	## Trimmed, no trailing slash: what is stored and what requests are built on.
	var out := raw_url.strip_edges()
	while out.ends_with("/"):
		out = out.substr(0, out.length() - 1)
	return out


static func check(raw_url: String) -> Dictionary:
	## {level: Level, message: String, url: String (normalised), host: String}
	var url := normalise(raw_url)
	var parts := split(url)
	if parts.is_empty():
		return _result(Level.REFUSED, "That is not a valid http(s) address.", url, "")
	var scheme: String = parts["scheme"]
	var host: String = parts["host"]
	if is_loopback(host):
		return _result(Level.REFUSED, "That address is this headset itself (localhost). Use the server's own address on your network, or an https:// tunnel.", url, host)
	if host == "10.0.2.2":
		return _result(Level.REFUSED, "10.0.2.2 is the Android emulator's name for its own computer; a headset cannot use it.", url, host)
	if host.begins_with("169.254.") or host.begins_with("fe80:"):
		return _result(Level.REFUSED, "That is a link-local address, which only works on one cable or adapter. Use the server's network address.", url, host)
	var local := is_local_network(host)
	if scheme == SCHEME_HTTP:
		if not local:
			return _result(Level.REFUSED, "Plain http:// is only allowed on your own network. Use an https:// address.", url, host)
		return _result(Level.WARN, "Plain http on your own network: the headset must be on the same Wi-Fi, and the key travels unencrypted.", url, host)
	if host.ends_with(".local"):
		return _result(Level.WARN, "A .local name may not resolve on the headset. If it cannot connect, use the server's IP address.", url, host)
	if is_tailnet(host):
		return _result(Level.WARN, "A Tailscale address: the headset must be on the same tailnet.", url, host)
	if local:
		return _result(Level.WARN, "A local https:// server needs a certificate the headset trusts; a self-signed one is refused.", url, host)
	return _result(Level.OK, "A public https:// address.", url, host)


static func check_relay(raw_url: String) -> Dictionary:
	## The Browser window's relay (DIDSA-CAD browser-relay/): a WebSocket address, ws:// or wss://, under the same rules as a server's address
	## (plain ws:// only on your own network). An http(s):// address is taken as the matching ws(s):// one, since that is easy to type by mistake.
	## Same shape as check(); `url` comes back as ws:// or wss://. (Before 10 Nov 2026 a pairing code's relay went through check(), which refused
	## every ws:// address: a relay could never be paired.)
	var url := normalise(raw_url)
	var lower := url.to_lower()
	var as_http := url
	if lower.begins_with("wss://"):
		as_http = "https://" + url.substr(6)
	elif lower.begins_with("ws://"):
		as_http = "http://" + url.substr(5)
	elif not (lower.begins_with("https://") or lower.begins_with("http://")):
		return _result(Level.REFUSED, "That is not a valid ws:// or wss:// address.", url, "")
	var out := check(as_http)
	var ws_url: String = str(out["url"])
	if ws_url.to_lower().begins_with("https://"):
		ws_url = "wss://" + ws_url.substr(8)
	elif ws_url.to_lower().begins_with("http://"):
		ws_url = "ws://" + ws_url.substr(7)
	if ws_url.to_lower().ends_with("/ws"):
		ws_url = ws_url.substr(0, ws_url.length() - 3) # the Browser window adds /ws itself
	out["url"] = ws_url
	out["message"] = str(out["message"]).replace("Plain http://", "Plain ws://").replace("Plain http", "Plain ws").replace("http(s)", "ws(s)").replace("https://", "wss://")
	return out


static func split(url: String) -> Dictionary:
	## {scheme, host, port, path} for an http(s) URL with a host, else {}. IPv6 hosts are not unwrapped beyond their brackets.
	var lower := url.to_lower()
	var scheme := ""
	if lower.begins_with("https://"):
		scheme = SCHEME_HTTPS
	elif lower.begins_with("http://"):
		scheme = SCHEME_HTTP
	else:
		return {}
	var rest := url.substr(scheme.length() + 3)
	var slash := rest.find("/")
	var authority := rest if slash == -1 else rest.substr(0, slash)
	var path := "" if slash == -1 else rest.substr(slash)
	if authority.contains("@") or authority.contains(" "):
		return {} # credentials or spaces in the address: refuse rather than guess
	var host := authority
	var port := 0
	if authority.begins_with("["):
		var close := authority.find("]")
		if close == -1:
			return {}
		host = authority.substr(1, close - 1)
		if authority.length() > close + 1:
			if authority[close + 1] != ":":
				return {}
			port = int(authority.substr(close + 2))
	elif authority.count(":") == 1:
		host = authority.get_slice(":", 0)
		var port_text := authority.get_slice(":", 1)
		if not port_text.is_valid_int():
			return {}
		port = int(port_text)
	elif authority.count(":") > 1:
		return {} # an unbracketed IPv6 address
	if host.is_empty():
		return {}
	return {"scheme": scheme, "host": host.to_lower(), "port": port, "path": path}


static func is_loopback(host: String) -> bool:
	return host == "localhost" or host.ends_with(".localhost") or host.begins_with("127.") or host == "::1" or host == "0.0.0.0"


static func ipv4(host: String) -> Array:
	var pieces := host.split(".")
	if pieces.size() != 4:
		return []
	var out := []
	for piece in pieces:
		if not piece.is_valid_int():
			return []
		var value := int(piece)
		if value < 0 or value > 255:
			return []
		out.append(value)
	return out


static func is_tailnet(host: String) -> bool:
	if host.ends_with(".ts.net"):
		return true
	var ip := ipv4(host)
	return not ip.is_empty() and ip[0] == 100 and ip[1] >= 64 and ip[1] <= 127


static func is_local_network(host: String) -> bool:
	## RFC 1918, Tailscale's range, an IPv6 unique-local address, a .local / .lan / .home.arpa name, or a bare machine name with no dot.
	if host.ends_with(".local") or host.ends_with(".lan") or host.ends_with(".home.arpa"):
		return true
	if is_tailnet(host):
		return true
	var ip := ipv4(host)
	if not ip.is_empty():
		return ip[0] == 10 or (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) or (ip[0] == 192 and ip[1] == 168)
	if host.contains(":"):
		return host.begins_with("fc") or host.begins_with("fd")
	return not host.contains(".")


static func default_name(url: String) -> String:
	var parts := split(normalise(url))
	return "DIDSA server" if parts.is_empty() else str(parts["host"])


static func _result(level: Level, message: String, url: String, host: String) -> Dictionary:
	return {"level": level, "message": message, "url": url, "host": host}
