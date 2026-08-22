module mcp;

import std::io;




<*
 How a request arrived, and therefore how it must be answered. A connection
 does not get to change its mind: whichever shape the first bytes had is the
 shape the response is written in.
*>
enum Framing
{
	// One JSON object per line, which is what a stdio MCP client speaks and
	// what the relay forwards. An LSP-style `Content-Length` header is read as
	// this too — it is a framing of the request only, and the answer goes back
	// as a plain line.
	LINE,

	// An HTTP/1.1 request, from an MCP client given a URL rather than a command
	// to launch. Answered with an HTTP/1.1 response and the connection closed.
	HTTP,
}

<*
 One request off the wire, with enough about how it came to answer it.
*>
struct Incoming
{
	Framing framing;

	// The JSON, allocated from the allocator handed to `read_request` — the
	// caller frees it. Empty on EOF, and on an HTTP request that carried no body.
	String body;

	// Who is asking, from the `Mcp-Session-Id` header, and allocated and freed
	// exactly like `body`. Empty when the client sent none, which is every
	// client that is not the relay — a `curl` by hand, or an older relay — and
	// is a legitimate answer rather than a failure.
	//
	// It is here because one connection carries one message and is then closed:
	// there is no connection for a server to hang a session on, so identity
	// either rides on the message or does not exist. A server that has several
	// clients editing one document needs it to say which of them did something,
	// and one that has a single client can ignore the field entirely.
	String session;

	// An HTTP request that is not a POST. There is nothing to hand a server, and
	// the answer is 405 rather than silence — a client probing for a stream it
	// cannot have should be told so, not left hanging.
	bool refused;
}

<*
 Read one request from the stream, in whichever framing it arrives.

 Three shapes, told apart by the first line: an HTTP request line (`POST /mcp
 HTTP/1.1`), an LSP-style `Content-Length` header, or the JSON itself. The
 first two are followed by headers to the blank line and then exactly
 Content-Length bytes.

 A zero-length body with nothing refused is EOF.

 @param allocator : `Where the body and the session are allocated. Name one explicitly when the buffers are freed on a different thread than this call runs on: the default is per-thread, so the two sides would otherwise be different allocators.`
*>
fn Incoming read_request(InStream stream, Allocator allocator = mem)
{
	DString first = dstring::new(mem);
	defer first.free();
	if (!read_line(stream, &first)) return {};

	String line = first.str_view();
	if (line.len == 0) return {};

	// "<verb> <target> HTTP/1.1" — the version at the end is what makes this an
	// HTTP request rather than a JSON document that happens to start with a
	// word, which nothing valid does anyway.
	if (line.contains("HTTP/1."))
	{
		if (!line.starts_with("POST"))
		{
			return { .framing = HTTP, .refused = true };
		}
		Headers headers = read_headers(stream, allocator);
		// Freed rather than carried out: there is no body to answer for, so
		// nothing downstream will ever see this `Incoming` again to free it.
		if (headers.length == 0)
		{
			if (headers.session.len > 0) alloc::free(allocator, headers.session);
			return { .framing = HTTP };
		}
		return {
			.framing = HTTP,
			.body = read_body(stream, headers.length, allocator),
			.session = headers.session,
		};
	}

	if (line.contains("Content-Length:"))
	{
		usz length = 0;
		if (try pos = line.index_of("Content-Length:"))
		{
			length = (usz)(line[pos + 15..].trim().to_uint() ?? 0);
		}
		if (length == 0) return {};
		// The length is on the first line and the rest of the headers follow it,
		// which is why the relay writes `Content-Length` first: a message whose
		// first header is anything else is read as a bare JSON line by the
		// branch below and comes apart. Everything after it is free to be in any
		// order, and `Mcp-Session-Id` is what the relay puts there.
		Headers headers = read_headers(stream, allocator);
		return { .body = read_body(stream, length, allocator), .session = headers.session };
	}

	return { .body = first.copy_str(allocator) };
}

<*
 Read one message from the stream: a bare JSON line, one Content-Length framed
 message, or the body of an HTTP request. Returns the message — the caller frees
 it — or the empty string on EOF.

 The framing is dropped on the floor, so this is for a caller that answers the
 same way whatever arrives: stdin, or a response coming back over a socket
 that was written as a line. A server that has to answer in kind wants
 `read_request`.
*>
fn String read_message(InStream stream, Allocator allocator = mem)
{
	Incoming incoming = read_request(stream, allocator);
	// The session goes the way of the framing, and for the same reason: a caller
	// that answers the same way whatever arrives has nothing to tell clients
	// apart *for*, and it is allocated, so dropping it silently would leak.
	if (incoming.session.len > 0) alloc::free(allocator, incoming.session);
	return incoming.body;
}

<*
 `json` as one line, with the closing newline on it. Allocated from `allocator`;
 the caller frees it.

 **The line framing has to keep its own promise.** A tool's `input_schema` is the
 JSON most likely to have been written across several lines, because it is the
 part a person reads; spliced into a response those newlines are legal JSON,
 whitespace between tokens. A reader taking one message per line then stops at the
 first of them, and what it has is a truncated object — the failure looks like a
 malformed server rather than a framing mistake, which is what makes it worth
 fixing here instead of asking every payload to be written flat.

 Replacing them with spaces is safe on any valid payload: a newline inside a
 string is already escaped as two characters by every writer, so the only ones
 left are between tokens, where JSON treats all whitespace alike. Two bare tokens
 that needed a separator cannot be adjacent without a comma in the first place.
 Carriage returns go the same way, so a schema written on a Windows checkout does
 not leave a stray CR mid-message.

 HTTP needs none of this: `Content-Length` frames a body of any shape, which is
 why that path has always carried these payloads intact.
*>
fn String one_line(String json, Allocator allocator = mem)
{
	DString line = dstring::new(allocator);
	defer line.free();
	line.reserve(json.len + 1);

	foreach (character : json)
	{
		line.append_char(character == '\n' || character == '\r' ? ' ' : character);
	}
	line.append_char('\n');
	return line.copy_str(allocator);
}

<*
 Write `json` as one line on stdout, flushed — the stdio transport's answer.

 Built whole and written once. Writing the runs between the newlines as they are
 found is the obvious shape and truncates: `write` answers with how much it took
 and a short write is ordinary on a pipe, so a message of any size would arrive
 cut off at its first newline.
*>
fn void send_message(String json)
{
	String line = one_line(json);
	defer alloc::free(mem, line);

	io::stdout().write(line)!!;
	io::stdout().flush()!!;
}

<*
 The HTTP response for `json`, allocated from `mem`; the caller frees it.

 An empty payload is a notification's, and answers 202 with no body: there is
 no JSON-RPC response to send and 200-with-nothing would leave a client parsing
 an empty document. `Connection: close` because one connection carries one
 message, which is what `Listener` and the relay both assume.
*>
fn String http_response(String json)
{
	DString out = dstring::new(mem);
	defer out.free();

	if (json.len == 0)
	{
		out.append_string("HTTP/1.1 202 Accepted\r\n");
		out.append_string("Content-Length: 0\r\n");
		out.append_string("Connection: close\r\n\r\n");
		return out.copy_str(mem);
	}

	out.append_string("HTTP/1.1 200 OK\r\n");
	out.append_string("Content-Type: application/json\r\n");
	out.appendf("Content-Length: %d\r\n", json.len);
	out.append_string("Connection: close\r\n\r\n");
	out.append_string(json);
	return out.copy_str(mem);
}

<*
 The answer to an HTTP request this server will not take: a client asking for
 the SSE stream of a streamable-HTTP server that only answers POSTs.

 A static string — nothing to free.
*>
fn String http_refusal()
{
	return "HTTP/1.1 405 Method Not Allowed\r\nAllow: POST\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
}

<*
 Write all of `bytes`, however many writes that takes.

 A socket write takes what it has room for and reports how much; only a caller
 that loops has written the whole buffer. Stopping at the first short write
 truncates the JSON mid-token, and a client reads that as a malformed response
 rather than as a partial one — the same failure as a server that crashed, and
 far harder to place.

 It matters because the answers are no longer all small: an image block carries
 a few hundred kilobytes of base64, well past what a send buffer holds in one
 go, so a short write here is an ordinary event rather than a pathological one.

 @return `False when the stream stopped taking bytes before the end.`
*>
fn bool write_all(OutStream stream, String bytes) @private
{
	usz written = 0;
	while (written < bytes.len)
	{
		sz? taken = stream.write((char[])bytes[written..]);
		if (catch taken) return false;
		if (taken <= 0) return false;
		written += (usz)taken;
	}
	return true;
}

// ---------------------------------------------------------------------------

// One CRLF- or LF-terminated line, minus the terminator. False on EOF.
fn bool read_line(InStream stream, DString* into) @private
{
	while (true)
	{
		char? c = stream.read_byte();
		if (catch c) return false;
		if (c == '\n') return true;
		if (c != '\r') into.append_char(c);
	}
}

// The two things this transport reads out of a header block. Everything else
// is skipped: a header a server does not understand is not an error, and a
// client is free to send as many as it likes.
struct Headers @private
{
	usz length;
	String session;
}

// Headers to the blank line. `length` is whatever Content-Length said, and zero
// when the headers named none — which for a body-carrying request means
// "nothing to read" rather than "read to EOF": this transport has no chunked
// decoder. `session` is the `Mcp-Session-Id`, allocated from `allocator` and
// empty when unsent; the caller owns it.
fn Headers read_headers(InStream stream, Allocator allocator) @private
{
	Headers headers;
	while (true)
	{
		DString header = dstring::new(mem);
		defer header.free();
		if (!read_line(stream, &header)) return headers;

		String line = header.str_view();
		if (line.len == 0) return headers;

		// Header names are case-insensitive, and a client that sends
		// `content-length` is within its rights.
		usz split = (usz)(line.index_of_char(':') ?? (long)line.len);
		if (split >= line.len) continue;
		String name = line[:split];
		String value = line[split + 1..].trim();

		if (name.compare_to_ignore_case("Content-Length") == 0)
		{
			headers.length = (usz)(value.to_uint() ?? 0);
			continue;
		}
		if (name.compare_to_ignore_case("Mcp-Session-Id") == 0)
		{
			// Last one wins, and the first is released rather than leaked: a
			// client that repeats a header is malformed, not dangerous.
			if (headers.session.len > 0) alloc::free(allocator, headers.session);
			headers.session = value.len > 0 ? value.copy(allocator) : "";
		}
	}
}

// Exactly `length` bytes, or the empty string if the stream ends first. Only the
// returned copy comes from `allocator`; the read buffer is scratch that never
// leaves this call.
fn String read_body(InStream stream, usz length, Allocator allocator) @private
{
	char[] body = mem::new_array(char, (sz)length);
	defer mem::free(body);

	usz read_so_far = 0;
	while (read_so_far < length)
	{
		usz n = (usz)(stream.read(body[read_so_far..length - 1]) ?? 0);
		if (n == 0) return "";
		read_so_far += n;
	}
	return ((String)body[:length]).copy(allocator);
}
