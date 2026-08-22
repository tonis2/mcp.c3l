module mcp;

import std::io;


// Well clear of what is registered rather than snug against it, and the reason
// is `add_tool`'s assert: overflowing is a runtime abort, and `new_mcp_server`
// is called per `run_script` as well as at startup — so the tool that did not
// fit would take down a user's script rather than be refused. The array is by
// value, so the cost of the headroom is a larger `Server` on the stack.
const MAX_TOOLS = 48;
const MAX_RESOURCES = 8;

struct Server {
	ServerInfo info;
	ToolDef[MAX_TOOLS] tools;
	usz tools_len;
	ResourceDef[MAX_RESOURCES] resources;
	usz resources_len;

	<*
	 Who the message being handled came from, or empty.

	 `Listener.pump` sets it from the `Mcp-Session-Id` on the request and clears
	 it again the moment `handle_message` returns, so it is only meaningful
	 *inside* a handler and must not be stored — the buffer behind it is freed
	 with the message. A handler reaches it by holding the server's address in
	 its `user_data`.

	 It is on the server rather than in the handler signature because most
	 handlers do not care: a server whose state has one owner never asks. The
	 ones that do are the ones editing something shared, where the answer to
	 "who just emptied my document" is the difference between a bug report and a
	 sentence.
	*>
	String session;
}

fn Server new_server(ServerInfo info)
{
	Server s;
	s.info = info;
	s.tools_len = 0;
	s.resources_len = 0;
	return s;
}

fn void Server.add_tool(&self, ToolDef tool)
{
	assert(self.tools_len < MAX_TOOLS, "Too many tools registered");
	self.tools[self.tools_len] = tool;
	self.tools_len++;
}

fn void Server.add_resource(&self, ResourceDef resource)
{
	assert(self.resources_len < MAX_RESOURCES, "Too many resources registered");
	self.resources[self.resources_len] = resource;
	self.resources_len++;
}

<*
 Serve newline-delimited JSON-RPC on stdin/stdout until EOF.

 The stdio transport is for standalone use and smoke tests; crig drives the
 same `handle_message` over its own socket server instead.
*>
fn void Server.serve(&self)
{
	InStream stdin_stream = io::stdin();

	while (true)
	{
		String message = read_message(stdin_stream);
		if (message.len == 0) break;
		String response = self.handle_message(message);
		alloc::free(mem, message);
		if (response.len > 0)
		{
			send_message(response);
			alloc::free(mem, response);
		}
	}
}
