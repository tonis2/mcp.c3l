<*
 The stdio side of the transport: read JSON-RPC on stdin, ask a server
 listening on a socket, write its answer to stdout.

 This is what lets a client that only speaks stdio — Claude Code launching a
 command — talk to a server living inside a running application. The
 application listens (see `Listener`), the relay is a short-lived process the
 client owns, and neither has to know the other's lifetime.

 One connection per message, matching `Listener`: a request that arrives while
 the application is between frames is answered on the next one, and a relay
 killed mid-request leaves nothing behind.

 The application does not have to be running. A request that cannot reach it
 comes back as a JSON-RPC error naming the port, so a client sees a server that
 is up and complaining rather than one that failed to start — start the
 application and the next request goes through.

 The handshake is the exception, and `relay`'s `catalog` parameter is why. A
 client asks who you are and what you have the moment it launches, and a client
 that gets an error there is entitled to give up on the server for the rest of
 its run — which would make "start the application afterwards" a lie. Those
 answers are the same whether the application is up or not, so a catalog server
 built from the same tool definitions answers them locally.

 ## Starting one, and telling several apart

 The two optional parameters are for the case where clients are not supposed to
 share. `launch` lets a relay bring up an application of its own on first real
 use — the catalog covers the handshake, so nothing starts until a call arrives
 that genuinely needs the application, and a client that only ever lists the
 tools costs nothing. `session` names this relay on every message it forwards,
 which is the only way an application with several clients can say which of them
 did something: one connection carries one message and is then closed, so there
 is no connection to hang an identity on.
*>
module mcp;

import std::collections::object;


import std::encoding::json;
import std::io;
import std::net::tcp;

<*
 Start an application to forward to, or say why not.

 Called before the first message that needs one, and again before any later
 message once the application has gone — a window that was closed is not an
 error, it is a request to open another. An implementation that has one running
 already answers with its port and does nothing else, so this is cheap to call
 per message and must be.

 @param ctx : `Handed through from the relay untouched.`
 @param problem : `Where to write the sentence a client is shown when this returns 0. Left empty on success.`
 @return `The port the application is reachable on, or 0 when it could not be started.`
*>
alias LaunchFn = fn int(void* ctx, DString* problem);

<*
 Relay stdin/stdout to `host:port` until stdin ends.

 Blocking throughout: one message is read, forwarded and answered before the
 next is looked at, which is the order a client expects on a stdio pipe.

 @param host : `The address to forward to. Loopback in every intended use.`
 @param port : `The port the application's Listener is on. May be 0 when a launch function is given, which then names it.`
 @param catalog : `Answers the handshake while the application is down; null to fail those too.`
 @param session : `What to call this relay on the wire, or empty to stay anonymous. See the header.`
 @param launch : `Brings an application up on demand; null to only ever talk to one that is already there.`
 @param launch_ctx : `Handed to the launch function untouched.`
*>
fn void relay(String host, int port, Server* catalog = null, String session = "",
	LaunchFn launch = null, void* launch_ctx = null)
{
	InStream stdin_stream = io::stdin();

	while (true)
	{
		String message = read_message(stdin_stream);
		if (message.len == 0) break;
		defer alloc::free(mem, message);

		String response;
		if (launch != null && needs_application(message, catalog))
		{
			DString problem = dstring::new(mem);
			defer problem.free();

			int reachable = launch(launch_ctx, &problem);
			// The port `launch` answers with wins over the one this was called
			// with and is kept for every message after it: an application picked
			// its own port precisely because nobody could name one in advance.
			if (reachable > 0) port = reachable;
			response = reachable > 0
				? forward(host, port, message, catalog, session)
				: launch_failed_message(message, problem.str_view());
		}
		else
		{
			response = forward(host, port, message, catalog, session);
		}

		if (response.len == 0) continue;

		send_message(response);
		alloc::free(mem, response);
	}
}

<*
 Whether this message is one an application has to be running to answer.

 Two things are not: anything the catalog can answer out of the registration
 table, and any notification. The notification rule is what makes lazy launching
 work at all — a client sends `notifications/initialized` the moment the
 handshake is done, and starting a window for it would mean every session that
 merely *has* this server configured gets one whether or not it is ever used.
*>
fn bool needs_application(String message, Server* catalog) @private
{
	Object*? parsed = json::parse(mem, message);
	// Unparseable: the application cannot make sense of it either, and the error
	// that comes back should not have cost a launch.
	if (catch parsed) return false;
	defer parsed.free();

	if (!parsed.is_keyable()) return false;
	if (try found = parsed.get("id"))
	{
		if (found.is_null()) return false;
	}
	else
	{
		return false;
	}

	if (catalog == null) return true;
	return !catalog.answers_offline(parsed);
}

<*
 What to say when the application could not be started, carrying the request's
 own id so a client can match it to the call it made.

 `problem` is whatever `launch` wrote, which is the only place that knows what
 went wrong — this library knows how to ask for an application, not how to build
 one.
*>
fn String launch_failed_message(String message, String problem) @private
{
	Object*? parsed = json::parse(mem, message);
	if (catch parsed) return error_message(null, PARSE_ERROR, "Parse error");
	defer parsed.free();

	if (!parsed.is_keyable()) return "";

	Object* id = null;
	if (try found = parsed.get("id"))
	{
		if (!found.is_null()) id = found;
	}
	if (id == null) return "";

	return error_message(id, INTERNAL_ERROR,
		problem.len > 0 ? problem : "the application could not be started");
}

<*
 One request out, one answer back. Returns the answer allocated from `mem` —
 the caller frees it — or the empty string when there is nothing to say, which
 is a notification's answer and an unreachable server's answer to one.
*>
fn String forward(String host, int port, String message, Server* catalog, String session = "") @private
{
	if (port <= 0) return unreachable_message(host, port, message, catalog);

	TcpSocket? socket = tcp::connect(host, port);
	if (catch socket) return unreachable_message(host, port, message, catalog);
	TcpSocket connection = socket;
	defer (void)connection.close();

	// Length-framed rather than written as a line, because a line has nowhere to
	// put the session — and `write_all` rather than one `write`, because a
	// socket takes what it has room for and a script of any size is past that.
	String framed = request_frame(message, session);
	defer alloc::free(mem, framed);
	if (!write_all(&connection, framed)) return unreachable_message(host, port, message, catalog);

	// The far end closes when it is done, so EOF is a complete answer here
	// rather than a truncated one: an empty return means the message was a
	// notification, which is exactly what `Listener.pump` writes nothing for.
	return read_message(&connection);
}

<*
 One request, headers and all, allocated from `mem` — the caller frees it.

 `Content-Length` comes first because the other end tells a framed message from
 a bare JSON line by its first line, and only that header says "headers follow".
 An older application that has never heard of `Mcp-Session-Id` skips it as it
 skips every header it does not know, which is what makes a new relay safe in
 front of one.
*>
fn String request_frame(String message, String session) @private
{
	DString out = dstring::new(mem);
	defer out.free();
	out.reserve(message.len + 64);

	out.appendf("Content-Length: %d\r\n", message.len);
	if (session.len > 0) out.appendf("Mcp-Session-Id: %s\r\n", session);
	out.append_string("\r\n");
	out.append_string(message);
	return out.copy_str(mem);
}

<*
 What to say when the application is not listening.

 The handshake and the catalogs are answered from `catalog` when there is one:
 who the server is and what it offers are properties of the build, not of the
 running document, so answering them here is not a guess. Everything else — any
 call that would read or change state — is an error carrying the request's own
 id, so the client can match it to the call it made.

 A notification gets nothing back, unreachable or not; answering one would be a
 protocol error in its own right.
*>
fn String unreachable_message(String host, int port, String message, Server* catalog) @private
{
	Object*? parsed = json::parse(mem, message);
	if (catch parsed) return error_message(null, PARSE_ERROR, "Parse error");
	defer parsed.free();

	if (!parsed.is_keyable()) return "";

	Object* id = null;
	if (try found = parsed.get("id"))
	{
		if (!found.is_null()) id = found;
	}
	if (id == null) return "";

	if (catalog && catalog.answers_offline(parsed)) return catalog.handle_message(message);

	String text = string::format(mem,
		"No server on %s:%d — is the application running?", host, port);
	defer alloc::free(mem, text);
	return error_message(id, INTERNAL_ERROR, text);
}

<*
 Whether this request is one a catalog server can answer on its own.

 The four that describe the server rather than interrogate it. `resources/read`
 is deliberately not among them: a resource's text is content, and a stale copy
 of content is worse than an error saying where to get the real one.
*>
fn bool Server.answers_offline(&self, Object* request)
{
	String? method = request.get_string("method");
	if (catch method) return false;
	switch (method)
	{
		case "initialize":
		case "ping":
		case "tools/list":
		case "resources/list":
			return true;
		default:
			return false;
	}
}
