module mcp;



<*
 Append `s` to `out` with the JSON string escapes applied. The surrounding
 quotes are the caller's — this only makes the interior safe.
*>
fn void json_escape_into(DString* out, String s)
{
	foreach (c : s)
	{
		switch (c)
		{
			case '"':  out.append_string(`\"`);
			case '\\': out.append_string(`\\`);
			case '\n': out.append_string(`\n`);
			case '\r': out.append_string(`\r`);
			case '\t': out.append_string(`\t`);
			default:   out.append_char(c);
		}
	}
}
