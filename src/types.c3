module mcp;

import std::collections::object;

<*
 One tools/call. `args` is the parsed `params.arguments` object — null when
 the call carried none — borrowed for the call's duration; do not free it.

 Returns the tool's text payload, allocated from `mem` and freed by the
 caller once the response is written. A fault becomes a JSON-RPC error
 response carrying the fault's name, so a handler that validates input
 should fault with a name an agent can act on.
*>
alias ToolHandlerFn = fn String?(Object* args, void* user_data);

struct ToolDef {
	String name;
	String description;
	String input_schema;  // raw JSON, inserted verbatim into tools/list
	ToolHandlerFn handler;
	void* user_data;      // handed back to the handler untouched
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
