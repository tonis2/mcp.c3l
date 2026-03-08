# mcp.c3l

A [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) server library for C3. Build MCP tool servers that integrate with Claude Code, Claude Desktop, and other MCP clients.

## Installation

Add `mcp.c3l` to your project's dependency search path:

```json
{
  "dependency-search-paths": ["dependencies"],
  "dependencies": ["mcp"]
}
```

## Quick Start

```c3
module my_server;

import mcp;

fn ToolResult handle_greet(String tool_name, String args, void* user_data)
{
    return mcp::text_result("Hello from C3!");
}

fn void main()
{
    Server s = mcp::new_server({
        .name = "my-server",
        .version = "1.0.0",
    });

    s.add_tool({
        .name = "greet",
        .description = "Say hello",
        .input_schema = `{"type":"object","properties":{}}`,
        .handler = &handle_greet,
    });

    s.serve();
}
```

Build and run:

```sh
c3c build
```

## API

### Server

- `mcp::new_server(ServerInfo{...})` -- Create a new server
- `Server.add_tool(ToolDef{...})` -- Register a tool (max 32)
- `Server.serve()` -- Start the stdio event loop

### Tool Definitions

```c3
ToolDef {
    String name;            // Tool name
    String description;     // Shown to the LLM
    String input_schema;    // JSON Schema for parameters
    ToolHandlerFn handler;  // fn ToolResult(String tool_name, String args, void* user_data)
    void* user_data;        // Optional context pointer
}
```

### Tool Results

- `mcp::text_result(String text)` -- Return text content
- `mcp::error_result(String message)` -- Return an error
- `mcp::image_result(String base64_data, String mime_type)` -- Return an image

### JSON Helpers

The library includes lightweight JSON helpers for parsing tool arguments:

- `mcp::extract_string_value(String s)` -- Extract a quoted string value
- `mcp::extract_object_value(String s)` -- Extract a `{...}` object
- `mcp::extract_array_value(String s)` -- Extract a `[...]` array
- `mcp::skip_whitespace(String s)` -- Skip leading whitespace
- `mcp::json_escape_into(DString* out, String s)` -- Escape a string for JSON output

## Protocol

The library implements MCP over stdio using newline-delimited JSON-RPC 2.0. It handles `initialize`, `tools/list`, and `tools/call` messages automatically.
