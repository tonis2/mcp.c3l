module mcp;

import std::collections::object;
import std::core::dstring;
import std::core::mem;
import std::core::mem::allocator;
import std::core::string;
import std::encoding::json;

const String DEFAULT_PROTOCOL_VERSION = "2024-11-05";

const int PARSE_ERROR      = -32700;
const int INVALID_REQUEST  = -32600;
const int METHOD_NOT_FOUND = -32601;
const int INVALID_PARAMS   = -32602;
const int INTERNAL_ERROR   = -32603;

<*
 Dispatch one incoming JSON-RPC message and return the response.

 The return is allocated from `mem`; the caller frees it. A notification (a
 message with no `id`) gets no response, not even an error — the return is
 then the EMPTY STRING LITERAL, not an allocation, so only free a non-empty
 return. What "no response" means on the wire is the transport's call:
 stdio writes nothing, HTTP answers 202 with an empty body.
*>
fn String Server.handle_message(&self, String message)
{
	Object*? parsed = json::parse(mem, message);
	if (catch parsed)
	{
		return error_message(null, PARSE_ERROR, "Parse error");
	}
	defer parsed.free();

	if (!parsed.is_keyable())
	{
		return error_message(null, INVALID_REQUEST, "Invalid request: not a JSON object");
	}

	Object* id = null;
	if (try found = parsed.get("id"))
	{
		if (!found.is_null()) id = found;
	}

	String? method = parsed.get_string("method");
	if (catch method)
	{
		return error_message(id, INVALID_REQUEST, "Invalid request: missing method");
	}

	if (id == null) return "";

	switch (method)
	{
		case "initialize":     return self.on_initialize(parsed, id);
		case "ping":           return result_message(id, "{}");
		case "tools/list":     return self.on_tools_list(id);
		case "tools/call":     return self.on_tools_call(parsed, id);
		case "resources/list": return self.on_resources_list(id);
		case "resources/read": return self.on_resources_read(parsed, id);
		default:
			String text = string::format(mem, "Method not found: %s", method);
			defer alloc::free(mem, text);
			return error_message(id, METHOD_NOT_FOUND, text);
	}
}

fn String Server.on_initialize(&self, Object* request, Object* id)
{
	// Echo the client's protocol version back; default to the oldest spoken.
	String version = DEFAULT_PROTOCOL_VERSION;
	if (try params = request.get("params"))
	{
		if (params.is_keyable())
		{
			if (try given = params.get_string("protocolVersion")) version = given;
		}
	}

	DString out = dstring::new(mem);
	defer out.free();
	append_open(&out, id);
	out.append_string(`"result":{"protocolVersion":"`);
	json_escape_into(&out, version);
	out.append_string(`","capabilities":{"tools":{},"resources":{}},"serverInfo":{"name":"`);
	json_escape_into(&out, self.info.name);
	out.append_string(`","version":"`);
	json_escape_into(&out, self.info.version);
	out.append_string(`"}}}`);
	return out.copy_str(mem);
}

fn String Server.on_tools_list(&self, Object* id)
{
	DString out = dstring::new(mem);
	defer out.free();
	append_open(&out, id);
	out.append_string(`"result":{"tools":[`);
	for (usz i = 0; i < self.tools_len; i++)
	{
		if (i > 0) out.append_char(',');
		ToolDef* tool = &self.tools[i];
		out.append_string(`{"name":"`);
		json_escape_into(&out, tool.name);
		out.append_string(`","description":"`);
		json_escape_into(&out, tool.description);
		out.append_string(`","inputSchema":`);
		out.append_string(tool.input_schema.len > 0 ? tool.input_schema : "{}");
		out.append_char('}');
	}
	out.append_string(`]}}`);
	return out.copy_str(mem);
}

fn String Server.on_tools_call(&self, Object* request, Object* id)
{
	Object*? params = request.get("params");
	if (catch params) return error_message(id, INVALID_PARAMS, "Invalid params: expected an object with name and arguments");
	if (!params.is_keyable()) return error_message(id, INVALID_PARAMS, "Invalid params: expected an object with name and arguments");

	String? name = params.get_string("name");
	if (catch name)
	{
		return error_message(id, INVALID_PARAMS, "Invalid params: missing tool name");
	}

	Object* args = null;
	if (try given = params.get("arguments"))
	{
		if (!given.is_keyable())
		{
			return error_message(id, INVALID_PARAMS, "Invalid params: arguments must be an object");
		}
		args = given;
	}

	for (usz i = 0; i < self.tools_len; i++)
	{
		ToolDef* tool = &self.tools[i];
		if (tool.name != name) continue;

		DString detail = dstring::new(mem);
		defer detail.free();

		String? payload = tool.handler(args, tool.user_data, &detail);
		if (catch error = payload)
		{
			if (detail.len() > 0) return error_message(id, INTERNAL_ERROR, detail.str_view());
			String text = string::format(mem, "%s", error);
			defer alloc::free(mem, text);
			return error_message(id, INTERNAL_ERROR, text);
		}
		defer alloc::free(mem, payload);

		DString out = dstring::new(mem);
		defer out.free();
		append_open(&out, id);
		out.append_string(`"result":{"content":`);
		if (tool.raw_content)
		{
			// The handler built the blocks itself; see ToolDef.raw_content.
			out.append_string(payload);
		}
		else
		{
			out.append_string(`[{"type":"text","text":"`);
			json_escape_into(&out, payload);
			out.append_string(`"}]`);
		}
		out.append_string(`}}`);
		return out.copy_str(mem);
	}

	String text = string::format(mem, "Unknown tool: %s", name);
	defer alloc::free(mem, text);
	return error_message(id, INVALID_PARAMS, text);
}

fn String Server.on_resources_list(&self, Object* id)
{
	DString out = dstring::new(mem);
	defer out.free();
	append_open(&out, id);
	out.append_string(`"result":{"resources":[`);
	for (usz i = 0; i < self.resources_len; i++)
	{
		if (i > 0) out.append_char(',');
		ResourceDef* resource = &self.resources[i];
		out.append_string(`{"uri":"`);
		json_escape_into(&out, resource.uri);
		out.append_string(`","name":"`);
		json_escape_into(&out, resource.name);
		out.append_string(`","description":"`);
		json_escape_into(&out, resource.description);
		out.append_string(`","mimeType":"`);
		json_escape_into(&out, resource.mime_type);
		out.append_string(`"}`);
	}
	out.append_string(`]}}`);
	return out.copy_str(mem);
}

fn String Server.on_resources_read(&self, Object* request, Object* id)
{
	Object*? params = request.get("params");
	if (catch params) return error_message(id, INVALID_PARAMS, "Invalid params: expected an object with a uri");
	if (!params.is_keyable()) return error_message(id, INVALID_PARAMS, "Invalid params: expected an object with a uri");

	String? uri = params.get_string("uri");
	if (catch uri)
	{
		return error_message(id, INVALID_PARAMS, "Invalid params: missing resource uri");
	}

	for (usz i = 0; i < self.resources_len; i++)
	{
		ResourceDef* resource = &self.resources[i];
		if (resource.uri != uri) continue;

		String? text = resource.handler(resource.user_data);
		if (catch error = text)
		{
			String message = string::format(mem, "%s", error);
			defer alloc::free(mem, message);
			return error_message(id, INTERNAL_ERROR, message);
		}
		defer alloc::free(mem, text);

		DString out = dstring::new(mem);
		defer out.free();
		append_open(&out, id);
		out.append_string(`"result":{"contents":[{"uri":"`);
		json_escape_into(&out, resource.uri);
		out.append_string(`","mimeType":"`);
		json_escape_into(&out, resource.mime_type);
		out.append_string(`","text":"`);
		json_escape_into(&out, text);
		out.append_string(`"}]}}`);
		return out.copy_str(mem);
	}

	String text = string::format(mem, "Unknown resource: %s", uri);
	defer alloc::free(mem, text);
	return error_message(id, INVALID_PARAMS, text);
}

// The fixed head of every response: {"jsonrpc":"2.0","id":<id>,
fn void append_open(DString* out, Object* id) @private
{
	out.append_string(`{"jsonrpc":"2.0","id":`);
	write_id(out, id);
	out.append_char(',');
}

// The id is echoed back exactly as it arrived: strings re-quoted and
// escaped, numbers and bools printed by Object's own JSON form.
fn void write_id(DString* out, Object* id) @private
{
	if (id == null || id.is_null())
	{
		out.append_string("null");
		return;
	}
	if (id.is_string())
	{
		out.append_char('"');
		json_escape_into(out, id.s);
		out.append_char('"');
		return;
	}
	out.appendf("%s", id);
}

fn String result_message(Object* id, String raw_result) @private
{
	DString out = dstring::new(mem);
	defer out.free();
	append_open(&out, id);
	out.append_string(`"result":`);
	out.append_string(raw_result);
	out.append_char('}');
	return out.copy_str(mem);
}

fn String error_message(Object* id, int code, String message) @private
{
	DString out = dstring::new(mem);
	defer out.free();
	append_open(&out, id);
	out.appendf(`"error":{"code":%d,"message":"`, code);
	json_escape_into(&out, message);
	out.append_string(`"}}`);
	return out.copy_str(mem);
}
