module mcp;

import std::io;
import std::core::mem;

const MAX_TOOLS = 32;
const MAX_RESOURCES = 8;

struct Server {
	ServerInfo info;
	ToolDef[MAX_TOOLS] tools;
	usz tools_len;
	ResourceDef[MAX_RESOURCES] resources;
	usz resources_len;
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
