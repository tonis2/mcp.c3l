module mcp;

import std::io;
import std::core::dstring;
import std::core::mem;

<*
 Read one message from the stream: a bare JSON line, or one Content-Length
 framed message. Returns the message allocated from `mem` — the caller
 frees it — or the empty string on EOF.
*>
fn String read_message(InStream stream)
{
	DString line = dstring::new(mem);
	defer line.free();

	while (true)
	{
		if (try c = stream.read_byte())
		{
			if (c == '\n') break;
			if (c != '\r') line.append_char(c);
		}
		else
		{
			return "";
		}
	}

	String s = line.str_view();
	if (s.len == 0) return "";

	if (!s.contains("Content-Length:"))
	{
		return line.copy_str(mem);
	}

	uint content_length = 0;
	if (try pos = s.index_of("Content-Length:"))
	{
		content_length = s[pos + 15..].trim().to_uint() ?? 0;
	}
	if (content_length == 0) return "";

	// Remaining headers end at the empty line.
	while (true)
	{
		DString header = dstring::new(mem);
		defer header.free();
		while (true)
		{
			if (try c = stream.read_byte())
			{
				if (c == '\n') break;
				if (c != '\r') header.append_char(c);
			}
			else
			{
				return "";
			}
		}
		if (header.str_view().len == 0) break;
	}

	char[] body = mem::new_array(char, content_length);
	usz read_so_far = 0;
	while (read_so_far < content_length)
	{
		usz n = (usz)(stream.read(body[read_so_far..content_length - 1]) ?? 0);
		if (n == 0)
		{
			mem::free(body);
			return "";
		}
		read_so_far += n;
	}

	String text = ((String)body[:content_length]).copy(mem);
	mem::free(body);
	return text;
}

fn void send_message(String json)
{
	io::stdout().write(json)!!;
	io::stdout().write("\n")!!;
	io::stdout().flush()!!;
}
