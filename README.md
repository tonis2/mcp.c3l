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
import std::collections::object;


// Returns the tool's payload allocated from `mem`; the caller frees it. A
// fault becomes a JSON-RPC error, carrying whatever was written to `detail`
// or the fault's own name when nothing was.
fn String? handle_greet(Object* args, void* user_data, DString* detail)
{
    return "Hello from C3!".copy(mem);
}

fn void main()
{
    Server server = mcp::new_server({
        .name = "my-server",
        .version = "1.0.0",
    });

    server.add_tool({
        .name = "greet",
        .description = "Say hello",
        .input_schema = `{"type":"object","properties":{}}`,
        .handler = &handle_greet,
    });

    server.serve();   // stdio: read stdin, answer stdout, until EOF
}
```

Build and run:

```sh
c3c build
```

## Transports

`Server.handle_message(String) -> String` is the whole protocol: JSON-RPC in, JSON-RPC out, no I/O. Everything below is a way of getting bytes to it.

### stdio

`Server.serve()` reads newline-delimited (or `Content-Length` framed) JSON-RPC on stdin and answers on stdout, which is what a client that launches a command expects. It owns the thread until EOF.

### Socket, for a server inside a running application

An application with its own event loop cannot give up its thread to `serve()`, and its state usually belongs to one thread. `Listener` splits the two:

```c3
Listener listener;
listener.start(8808, &wake, ctx)!;   // binds 127.0.0.1; a thread accepts and reads
defer listener.stop();

while (app_running)
{
    draw_a_frame();
    listener.pump(&server);          // handlers run HERE, on this thread
}
```

The thread only moves bytes: accept, read one message, queue it (16 deep), call `wake`. `pump` is where `handle_message` runs, so handlers see the application's own thread and no lock is needed between them and its state. `wake` is called from the listener thread and exists for a loop that sleeps when idle — it should be that loop's "post an event" primitive, and may be null for an application that polls.

A request that arrives with a full mailbox is refused with a JSON-RPC error rather than dropped: a client waiting on a socket that will never answer is worse than one that is told no.

**One connection carries one message**, closed once the answer is written. Requests may arrive as:

- an HTTP/1.1 `POST` — answered `200` with `Content-Type: application/json`; a notification is answered `202` with no body, and a `GET` is answered `405 Allow: POST`. This is what an MCP client configured with a URL sends:
  `{"type": "http", "url": "http://127.0.0.1:8808/mcp"}`
- bare JSON on a line, or a `Content-Length` framed message — answered with a bare line.

The framing is per-connection and answers match what arrived, so both kinds of client can use the same port.

### Relay, for a client that can only launch a command

`relay(host, port, catalog)` is stdio on one side and a connection per message on the other. It holds no state, so it can be started and killed freely while the application it forwards to keeps running.

`catalog` is an optional `Server*` answering `initialize`, `ping`, `tools/list` and `resources/list` while the application is down — a client asks those the moment it starts and may write the server off for its whole run if they fail, and those four answers come from the build rather than from the application's state. Anything else, unreachable, is an error naming the port. Pass null to fail those too.

Prefer a URL where the client allows one: it needs no second process.

## API

### Server

- `mcp::new_server(ServerInfo{...})` — create a server
- `Server.add_tool(ToolDef{...})` — register a tool (max 32)
- `Server.add_resource(ResourceDef{...})` — register a resource (max 8)
- `Server.handle_message(String) -> String` — one request in, one response out; the empty string means "no response", which is a notification's answer
- `Server.serve()` — the stdio loop

### Tool definitions

```c3
ToolDef {
    String name;            // Tool name
    String description;     // Shown to the LLM
    String input_schema;    // JSON Schema, inserted verbatim into tools/list
    ToolHandlerFn handler;  // fn String?(Object* args, void* user_data, DString* detail)
    void* user_data;        // Handed back to the handler untouched
    bool raw_content;       // Handler returns the content array, not the text for one
}
```

`args` is the parsed `params.arguments` — null when the call carried none — borrowed for the call. The handler returns its payload allocated from `mem`.

A fault becomes a JSON-RPC error. Its message is whatever the handler left in `detail`, and the fault's own name when it left nothing — telling a model which value was rejected and what would have been accepted is the difference between a retry that works and one that guesses again. `detail` is never null, arrives empty, and is ignored unless the handler faults.

`raw_content` is for a tool whose answer is not text. Off — the default — the payload is escaped into one text block. On, it is spliced in as the `content` array verbatim, which is the only way to return anything else: an image block carries base64 in a `data` member beside a `mimeType`, and escaping that structure into a text block delivers the characters of the JSON rather than the JSON. A raw handler owns the array's well-formedness; nothing validates it.

```c3
// A raw handler's payload
`[{"type":"image","mimeType":"image/png","data":"iVBORw0KGgo..."}]`
```

### Resources

```c3
ResourceDef {
    String uri;
    String name;
    String description;
    String mime_type;
    ResourceHandlerFn handler;  // fn String?(void* user_data)
    void* user_data;
}
```

### Transport

- `Listener.start(int port, WakeFn wake = null, void* ctx = null)` — bind and accept
- `Listener.pump(Server*) -> usz` — answer what has arrived, on the calling thread
- `Listener.stop()` — join the thread and give the port back
- `relay(String host, int port, Server* catalog = null)` — stdio to socket
- `read_request(InStream) -> Incoming` — one request and the framing it came in
- `read_message(InStream) -> String` — the same, framing discarded
- `send_message(String)` — one line on stdout, flushed

### JSON

- `mcp::json_escape_into(DString* out, String s)` — escape a string for JSON output

Parsing is `std::encoding::json`; there is no hand-rolled scanner here.

## Protocol

JSON-RPC 2.0: `initialize`, `ping`, `tools/list`, `tools/call`, `resources/list`, `resources/read`. Unknown methods answer `-32601`, malformed input `-32700`, bad parameters `-32602`. A message with no `id` is a notification and is answered with nothing at all.
