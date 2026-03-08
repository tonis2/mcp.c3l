module mcp;

import std::core::dstring;

fn String skip_whitespace(String s){
	usz i = 0;
	while (i < s.len && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++;
	return s[i..];
}

fn uint parse_json_uint(String s){
	s = skip_whitespace(s);
	usz end = 0;
	while (end < s.len && s[end] >= '0' && s[end] <= '9') end++;
	if (end == 0) return 0;
	return s[:end].to_uint() ?? 0;
}

fn String extract_string_value(String s){
	usz start = 0;
	while (start < s.len && s[start] != '"') start++;
	start++;
	usz end = start;
	while (end < s.len && s[end] != '"') end++;
	if (start >= s.len) return "";
	return s[start..end - 1];
}

fn String extract_object_value(String s){
	s = skip_whitespace(s);
	if (s.len == 0 || s[0] != '{') return "{}";

	int depth = 0;
	for (usz i = 0; i < s.len; i++)
	{
		if (s[i] == '{') depth++;
		if (s[i] == '}')
		{
			depth--;
			if (depth == 0) return s[..i];
		}
	}
	return "{}";
}

fn String extract_array_value(String s){
	s = skip_whitespace(s);
	if (s.len == 0 || s[0] != '[') return "[]";

	int depth = 0;
	for (usz i = 0; i < s.len; i++)
	{
		if (s[i] == '[') depth++;
		if (s[i] == ']')
		{
			depth--;
			if (depth == 0) return s[..i];
		}
	}
	return "[]";
}

fn void json_escape_into(DString* out, String s){
	foreach (c : s)
	{
		switch (c)
		{
			case '"': out.append("\\\"");
			case '\\': out.append("\\\\");
			case '\n': out.append("\\n");
			case '\r': out.append("\\r");
			case '\t': out.append("\\t");
			default: out.append_char(c);
		}
	}
}
