module mcp;

import std::io;
import std::core::dstring;
import std::core::mem;

// Read one message from stdin. Supports bare JSON lines and Content-Length framing.
// Returns the message string, or empty string on EOF.
fn String read_message(InStream stream)
{
	DString line = dstring::new(mem);
	defer line.free();

	// Read until \n
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

	// Content-Length framed message
	if (s.contains("Content-Length:"))
	{
		uint content_length = 0;
		if (try cl_pos = s.index_of("Content-Length:"))
		{
			content_length = parse_json_uint(s[cl_pos + 15..]);
		}
		if (content_length == 0) return "";

		// Skip remaining headers until empty line
		while (true)
		{
			DString hdr = dstring::new(mem);
			defer hdr.free();
			while (true)
			{
				if (try c = stream.read_byte())
				{
					if (c == '\n') break;
					if (c != '\r') hdr.append_char(c);
				}
				else
				{
					return "";
				}
			}
			if (hdr.str_view().len == 0) break;
		}

		// Read exactly content_length bytes
		char[] body = mem::new_array(char, content_length);
		usz read_so_far = 0;
		while (read_so_far < content_length)
		{
			usz n = stream.read(body[read_so_far..content_length - 1]) ?? 0;
			if (n == 0)
			{
				mem::free(body);
				return "";
			}
			read_so_far += n;
		}

		// Copy to a DString so caller owns the memory
		DString result = dstring::new(mem, (String)body[:content_length]);
		mem::free(body);
		return result.str_view();
	}

	// Bare JSON line — copy so it survives after line is freed
	DString result = dstring::new(mem, s);
	return result.str_view();
}

fn void send_message(String json)
{
	io::stdout().write(json)!!;
	io::stdout().write("\n")!!;
	io::stdout().flush()!!;
}
