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
*>
module mcp;

import std::collections::object;
import std::core::mem;
import std::core::mem::allocator;
import std::core::string;
import std::encoding::json;
import std::io;
import std::net::tcp;

<*
 Relay stdin/stdout to `host:port` until stdin ends.

 Blocking throughout: one message is read, forwarded and answered before the
 next is looked at, which is the order a client expects on a stdio pipe.

 @param host : `The address to forward to. Loopback in every intended use.`
 @param port : `The port the application's Listener is on.`
 @param catalog : `Answers the handshake while the application is down; null to fail those too.`
*>
fn void relay(String host, int port, Server* catalog = null)
{
	InStream stdin_stream = io::stdin();

	while (true)
	{
		String message = read_message(stdin_stream);
		if (message.len == 0) break;
		defer alloc::free(mem, message);

		String response = forward(host, port, message, catalog);
		if (response.len == 0) continue;

		send_message(response);
		alloc::free(mem, response);
	}
}

<*
 One request out, one answer back. Returns the answer allocated from `mem` —
 the caller frees it — or the empty string when there is nothing to say, which
 is a notification's answer and an unreachable server's answer to one.
*>
fn String forward(String host, int port, String message, Server* catalog) @private
{
	TcpSocket? socket = tcp::connect(host, port);
	if (catch socket) return unreachable_message(host, port, message, catalog);
	TcpSocket connection = socket;
	defer (void)connection.close();

	if (catch connection.write(message)) return unreachable_message(host, port, message, catalog);
	if (catch connection.write("\n")) return unreachable_message(host, port, message, catalog);

	// The far end closes when it is done, so EOF is a complete answer here
	// rather than a truncated one: an empty return means the message was a
	// notification, which is exactly what `Listener.pump` writes nothing for.
	return read_message(&connection);
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
