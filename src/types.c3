module mcp;

import std::collections::object;
import std::core::dstring;

<*
 One tools/call. `args` is the parsed `params.arguments` object — null when
 the call carried none — borrowed for the call's duration; do not free it.

 Returns the tool's text payload, allocated from `mem` and freed by the
 caller once the response is written — or the whole content array, when the
 tool was registered with `raw_content`.

 A fault becomes a JSON-RPC error response. Its message is whatever the
 handler left in `detail`, and the fault's own name when it left nothing:
 telling an agent which value was rejected and what would have been accepted
 is the difference between a retry that works and one that guesses again, and
 a fault name carries neither. `detail` is never null, arrives empty, and is
 ignored unless the handler faults.
*>
alias ToolHandlerFn = fn String?(Object* args, void* user_data, DString* detail);

struct ToolDef {
	String name;
	String description;
	String input_schema;  // raw JSON, inserted verbatim into tools/list
	ToolHandlerFn handler;
	void* user_data;      // handed back to the handler untouched

	<*
	 Whether the handler returns the `content` array itself rather than the text
	 to put in one.

	 Off is the ordinary tool: the payload is escaped into a single text block,
	 which is every answer that is words or JSON. On is for a tool whose answer
	 is not text at all — an image block carries base64 in a `data` member beside
	 a `mimeType`, and escaping that structure into a text block would deliver
	 the characters of the JSON instead of the JSON.

	 A raw handler's payload is spliced into the response verbatim, so it must be
	 a well-formed JSON array of content blocks. Nothing here validates it: a
	 malformed one is a malformed response.
	*>
	bool raw_content;
}

<*
 One resources/read. Returns the resource's text, allocated from `mem` and
 freed by the caller. A fault becomes a JSON-RPC error response.
*>
alias ResourceHandlerFn = fn String?(void* user_data);

struct ResourceDef {
	String uri;
	String name;
	String description;
	String mime_type;
	ResourceHandlerFn handler;
	void* user_data;
}

struct ServerInfo {
	String name;
	String version;
}
