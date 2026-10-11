class_name OpenJevHttp
extends RefCounted

## OPENJEV LIVE V0 — blocking bounded localhost HTTP helpers.
## Same pattern as the JEV shadow transport: fresh HTTPClient per call,
## absolute deadline, never raises. Bodies are small JSON.


static func get_json(host: String, port: int, path: String,
	timeout_ms: int) -> Dictionary:
	return _request(HTTPClient.METHOD_GET, host, port, path, "", timeout_ms)


static func post_json(host: String, port: int, path: String, body: String,
	timeout_ms: int) -> Dictionary:
	return _request(HTTPClient.METHOD_POST, host, port, path, body, timeout_ms)


static func _request(method: int, host: String, port: int, path: String,
	body: String, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var http := HTTPClient.new()
	var err := http.connect_to_host(host, port)
	if err != OK:
		return {"ok": false, "error": "CONNECT_FAIL: %s" % error_string(err)}
	while true:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false, "error": "TIMEOUT_CONNECT"}
		http.poll()
		var st := http.get_status()
		if st == HTTPClient.STATUS_CONNECTED:
			break
		if st != HTTPClient.STATUS_RESOLVING and st != HTTPClient.STATUS_CONNECTING:
			http.close()
			return {"ok": false, "error": "CONNECT_STATUS_%d" % st}
		OS.delay_msec(5)
	if method == HTTPClient.METHOD_POST:
		err = http.request(method, path,
			PackedStringArray(["Content-Type: application/json"]), body)
	else:
		err = http.request(method, path, PackedStringArray(), "")
	if err != OK:
		http.close()
		return {"ok": false, "error": "REQUEST_FAIL: %s" % error_string(err)}
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false, "error": "TIMEOUT_REQUEST"}
		http.poll()
		OS.delay_msec(5)
	if http.get_response_code() != 200:
		var code := http.get_response_code()
		http.close()
		return {"ok": false, "error": "HTTP_%d" % code}
	var chunks := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false, "error": "TIMEOUT_BODY"}
		http.poll()
		var chunk := http.read_response_body_chunk()
		if chunk.size() > 0:
			chunks.append_array(chunk)
		else:
			OS.delay_msec(2)
	http.close()
	return {"ok": true, "body": chunks.get_string_from_utf8()}
