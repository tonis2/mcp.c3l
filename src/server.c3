module mcp;

import std::io;

const MAX_TOOLS = 32;

struct Server {
	ServerInfo info;
	ToolDef[MAX_TOOLS] tools;
	usz tools_len;
}

fn Server new_server(ServerInfo info)
{
	Server s;
	s.info = info;
	s.tools_len = 0;
	return s;
}

fn void Server.add_tool(&self, ToolDef tool)
{
	assert(self.tools_len < MAX_TOOLS, "Too many tools registered");
	self.tools[self.tools_len] = tool;
	self.tools_len++;
}

fn void Server.serve(&self)
{
	InStream stdin_stream = io::stdin();

	while (true)
	{
		String message = read_message(stdin_stream);
		if (message.len == 0) break;
		handle_message(self, message);
	}
}
