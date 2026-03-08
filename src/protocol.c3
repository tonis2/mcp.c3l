module mcp;

import std::core::dstring;

fn void handle_message(Server* server, String message) @private
{
	uint request_id = 0;
	DString method = dstring::new(mem);
	defer method.free();

	// Extract id
	if (try id_pos = message.index_of(`"id"`))
	{
		if (try colon = message[id_pos..].index_of_char(':'))
		{
			String after = message[id_pos + colon + 1..];
			request_id = parse_json_uint(after);
		}
	}

	// Extract method
	if (try method_pos = message.index_of(`"method"`))
	{
		if (try colon = message[method_pos..].index_of_char(':'))
		{
			String after = message[method_pos + colon + 1..];
			String val = extract_string_value(after);
			method.append_bytes(val);
		}
	}

	String m = method.str_view();

	if (m == "initialize")
	{
		handle_initialize(server, message, request_id);
	}
	else if (m == "notifications/initialized")
	{
		// No-op
	}
	else if (m == "tools/list")
	{
		handle_tools_list(server, request_id);
	}
	else if (m == "tools/call")
	{
		handle_tools_call(server, message, request_id);
	}
	else
	{
		DString resp = dstring::new(mem);
		defer resp.free();
		resp.appendf(`{"jsonrpc":"2.0","id":%d,"error":{"code":-32601,"message":"Method not found"}}`, request_id);
		send_message(resp.str_view());
	}
}

fn void handle_initialize(Server* server, String message, uint id) @private
{
	// Extract protocol version from request
	DString proto_ver = dstring::new(mem);
	defer proto_ver.free();
	if (try pos = message.index_of(`"protocolVersion"`))
	{
		if (try colon = message[pos..].index_of_char(':'))
		{
			String after = message[pos + colon + 1..];
			String val = extract_string_value(after);
			proto_ver.append_bytes(val);
		}
	}
	if (proto_ver.str_view().len == 0)
	{
		proto_ver.appendf("2024-11-05");
	}

	DString resp = dstring::new(mem);
	defer resp.free();
	resp.appendf(`{"jsonrpc":"2.0","id":%d,"result":`, id);
	resp.appendf(`{"protocolVersion":"%s",`, proto_ver.str_view());
	resp.appendf(`"capabilities":{"tools":{}},`);
	resp.appendf(`"serverInfo":{"name":"`);
	json_escape_into(&resp, server.info.name);
	resp.appendf(`","version":"`);
	json_escape_into(&resp, server.info.version);
	resp.appendf(`"}}}`);
	send_message(resp.str_view());
}

fn void handle_tools_list(Server* server, uint id) @private
{
	DString resp = dstring::new(mem);
	defer resp.free();
	resp.appendf(`{"jsonrpc":"2.0","id":%d,"result":{"tools":[`, id);

	for (usz i = 0; i < server.tools_len; i++)
	{
		if (i > 0) resp.appendf(",");
		ToolDef* tool = &server.tools[i];
		resp.appendf(`{"name":"`);
		json_escape_into(&resp, tool.name);
		resp.appendf(`","description":"`);
		json_escape_into(&resp, tool.description);
		resp.appendf(`","inputSchema":`);
		resp.appendf("%s", tool.input_schema);
		resp.appendf("}");
	}

	resp.appendf(`]}}`);
	send_message(resp.str_view());
}

fn void handle_tools_call(Server* server, String message, uint id) @private
{
	// Extract tool name from params.name
	DString tool_name_buf = dstring::new(mem);
	defer tool_name_buf.free();

	if (try params_pos = message.index_of(`"params"`))
	{
		String params_section = message[params_pos..];
		if (try name_pos = params_section.index_of(`"name"`))
		{
			if (try colon = params_section[name_pos..].index_of_char(':'))
			{
				String after = params_section[name_pos + colon + 1..];
				String val = extract_string_value(after);
				tool_name_buf.append_bytes(val);
			}
		}
	}

	// Extract arguments
	DString args = dstring::new(mem);
	defer args.free();
	if (try args_pos = message.index_of(`"arguments"`))
	{
		if (try colon = message[args_pos..].index_of_char(':'))
		{
			String after = message[args_pos + colon + 1..];
			String val = extract_object_value(after);
			args.append_bytes(val);
		}
	}
	else
	{
		args.appendf("{}");
	}

	String tool_name = tool_name_buf.str_view();

	// Find the tool
	ToolDef* found_tool = null;
	for (usz i = 0; i < server.tools_len; i++)
	{
		if (server.tools[i].name == tool_name)
		{
			found_tool = &server.tools[i];
			break;
		}
	}

	if (found_tool == null)
	{
		send_error_response(id, "Unknown tool");
		return;
	}

	// Call handler
	ToolResult result = found_tool.handler(tool_name, args.str_view(), found_tool.user_data);

	// Format response
	format_tool_response(id, &result);
}

fn void format_tool_response(uint id, ToolResult* result) @private
{
	DString resp = dstring::new(mem);
	defer resp.free();

	resp.appendf(`{"jsonrpc":"2.0","id":%d,"result":{"content":[`, id);

	for (usz i = 0; i < result.content_len; i++)
	{
		if (i > 0) resp.appendf(",");
		ContentItem* item = &result.content[i];

		switch (item.type)
		{
			case TEXT:
				resp.appendf(`{"type":"text","text":"`);
				json_escape_into(&resp, item.text);
				resp.appendf(`"}`);
			case IMAGE:
				resp.appendf(`{"type":"image","data":"`);
				resp.appendf("%s", item.data);
				resp.appendf(`","mimeType":"`);
				json_escape_into(&resp, item.mime_type);
				resp.appendf(`"}`);
		}
	}

	if (result.is_error)
	{
		resp.appendf(`],"isError":true}}`);
	}
	else
	{
		resp.appendf(`]}}`);
	}

	send_message(resp.str_view());
}

fn void send_error_response(uint id, String message) @private
{
	DString resp = dstring::new(mem);
	defer resp.free();
	resp.appendf(`{"jsonrpc":"2.0","id":%d,"error":{"code":-32603,"message":"`);
	json_escape_into(&resp, message);
	resp.appendf(`"}}`);
	send_message(resp.str_view());
}
