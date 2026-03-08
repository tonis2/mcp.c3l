module mcp;

import std::core::dstring;

enum ContentType {
	TEXT,
	IMAGE,
}

struct ContentItem {
	ContentType type;
	String text;
	String data;       // base64 for IMAGE
	String mime_type;  // e.g. "image/png"
}

struct ToolResult {
	ContentItem[8] content;
	usz content_len;
	bool is_error;
}

alias ToolHandlerFn = fn ToolResult(String tool_name, String args, void* user_data);

struct ToolDef {
	String name;
	String description;
	String input_schema;  // Raw JSON for inputSchema
	ToolHandlerFn handler;
	void* user_data;
}

struct ServerInfo {
	String name;
	String version;
}

fn ToolResult text_result(String text)
{
	ToolResult r;
	r.content[0] = { .type = TEXT, .text = text };
	r.content_len = 1;
	return r;
}

fn ToolResult error_result(String message)
{
	ToolResult r;
	r.content[0] = { .type = TEXT, .text = message };
	r.content_len = 1;
	r.is_error = true;
	return r;
}

fn ToolResult image_result(String base64_data, String mime_type)
{
	ToolResult r;
	r.content[0] = { .type = IMAGE, .data = base64_data, .mime_type = mime_type };
	r.content_len = 1;
	return r;
}
