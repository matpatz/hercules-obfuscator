local FunctionInliner = {}
local Parser = require("Parser")
local Ast = require("Parser/Ast")
local config = require("config")

-- Helper: skip over strings in code, returns position after the string
local function skip_string(code, pos)
    local char = code:sub(pos, pos)
    if char == '"' or char == "'" then
        local quote = char
        pos = pos + 1
        while pos <= #code do
            local c = code:sub(pos, pos)
            if c == "\\" then
                pos = pos + 2
            elseif c == quote then
                return pos + 1
            else
                pos = pos + 1
            end
        end
    elseif char == "[" then
        -- long string bracket [=*[ ... ]=*] of any level
        local eq = 0
        local i = pos + 1
        while code:byte(i) == 61 do eq = eq + 1 i = i + 1 end
        if code:byte(i) == 91 then
            local close = "]" .. string.rep("=", eq) .. "]"
            local _, end_pos = code:find(close, i, true)
            return end_pos and end_pos + 1 or (#code + 1)
        end
    end
    return pos
end

-- Returns true if a long string bracket ([ or [=*[) starts at pos
local function long_bracket_at(code, pos)
    if code:byte(pos) ~= 91 then return false end
    local i = pos + 1
    while code:byte(i) == 61 do i = i + 1 end
    return code:byte(i) == 91
end

-- Collect all call sites of `name` in `text`, skipping strings and comments
-- (when `skip_strings` is true). Returns a list of { s, e, args } in source
-- order. When no strings/comments are present this is a plain fast find loop.
local function collect_calls(text, name, skip_strings)
    local calls = {}
    local pos, len = 1, #text
    local pattern = name .. "%s*(%b())"
    if not skip_strings then
        while pos <= len do
            local s, e, args = text:find(pattern, pos)
            if not s then break end
            calls[#calls + 1] = { s = s, e = e, args = args }
            pos = e + 1
        end
        return calls
    end
    while pos <= len do
        -- Earliest string/comment opener at/after pos: a quote or [, or a -- comment.
        -- (Lone '-' is never treated as an opener - subtraction is too common -
        -- so comments are matched only as the two-character -- sequence.)
        local nxt = nil
        local ql = text:find("[\"'%[]", pos)
        if ql then nxt = ql end
        local cm = text:find("%-%-", pos)
        if cm and (not nxt or cm < nxt) then nxt = cm end
        if nxt then
            local s, e, args = text:find(pattern, pos)
            if s and s < nxt then
                calls[#calls + 1] = { s = s, e = e, args = args }
                pos = e + 1
            else
                -- skip the string/comment starting at nxt
                if text:byte(nxt) == 45 then
                    -- -- comment: skip to end of line
                    local le = text:find("\n", nxt)
                    pos = (le and le + 1) or (len + 1)
                else
                    local after = skip_string(text, nxt)
                    pos = (after ~= nxt) and after or (nxt + 1)
                end
            end
        else
            -- No more strings/comments; collect all remaining call sites
            local s, e, args = text:find(pattern, pos)
            if not s then break end
            calls[#calls + 1] = { s = s, e = e, args = args }
            pos = e + 1
        end
    end
    return calls
end

-- Returns true if `text` contains any string/comment opener (" ' [ --).
local function has_string_or_comment(text)
    return text:find("[\"'%[]", 1) ~= nil or text:find("%-%-", 1) ~= nil
end

-- Returns true if byte b is a Lua identifier character (alphanumeric or _)
local function is_ident_byte(b)
    return (b >= 48 and b <= 57) or (b >= 65 and b <= 90)
        or (b >= 97 and b <= 122) or b == 95
end

-- Returns true if keyword `kw` starts at `pos` in `code` with a word boundary
-- after it (i.e. not immediately followed by an identifier character).
-- Uses byte checks so it is O(1) and never allocates a whole-remainder substring.
local function kw_at(code, pos, kw)
    if code:byte(pos) ~= kw:byte(1) then return false end
    if code:sub(pos, pos + #kw - 1) ~= kw then return false end
    local after = code:byte(pos + #kw)
    return after == nil or not is_ident_byte(after)
end

-- Helper: count block depth from a given position, handling strings and comments
-- Returns the position where the matching "end" keyword ends
-- Also handles: if/then/else/elseif, for, while, repeat/until, function/end, do/end
local function find_matching_end(code, start_pos)
    local depth = 1
    local pos = start_pos
    local skip_next_do = false  -- skip 'do' after 'for' or 'while'

    while pos <= #code and depth > 0 do
        local char = code:byte(pos)

        -- Skip strings
        if char == 34 or char == 39 or long_bracket_at(code, pos) then
            pos = skip_string(code, pos)
            goto continue
        end

        -- Skip comments
        if char == 45 and code:byte(pos + 1) == 45 then
            local line_end = code:find("\n", pos)
            pos = line_end and line_end + 1 or #code + 1
            goto continue
        end

        -- Check for block-opening keywords
        -- IMPORTANT: Check elseif BEFORE else and if to avoid partial matching
        -- elseif is NOT a block opener or closer, skip over it
        if kw_at(code, pos, "elseif") then
            pos = pos + 6
        elseif kw_at(code, pos, "for") then
            depth = depth + 1
            skip_next_do = true
            pos = pos + 3
        elseif kw_at(code, pos, "while") then
            depth = depth + 1
            skip_next_do = true
            pos = pos + 5
        elseif kw_at(code, pos, "do") then
            if not skip_next_do then
                depth = depth + 1
            end
            skip_next_do = false
            pos = pos + 2
        elseif kw_at(code, pos, "function") then
            depth = depth + 1
            pos = pos + 8
        elseif kw_at(code, pos, "if") then
            depth = depth + 1
            pos = pos + 2
        elseif kw_at(code, pos, "repeat") then
            depth = depth + 1
            pos = pos + 6
        elseif kw_at(code, pos, "end") then
            depth = depth - 1
            if depth == 0 then
                return pos + 3
            end
            pos = pos + 3
        elseif kw_at(code, pos, "until") then
            depth = depth - 1
            if depth == 0 then
                return pos + 5
            end
            pos = pos + 5
        else
            -- then, else, and other keywords are NOT block openers or closers
            pos = pos + 1
        end

        ::continue::
    end

    return pos
end

-- Check if a function body contains recursive calls to itself
local function is_recursive(name, body)
    -- Simple check: look for name( pattern outside of strings
    local pos = 1
    while pos <= #body do
        local char = body:byte(pos)
        -- Skip strings
        if char == 34 or char == 39 or long_bracket_at(body, pos) then
            pos = skip_string(body, pos)
            goto continue
        end
        -- Check for name( (anchored at pos; name is a plain identifier, no magic chars)
        if body:find("^" .. name .. "%s*%(", pos) then
            return true
        end
        pos = pos + 1
        ::continue::
    end
    return false
end

-- Find all function definitions and their bodies
local function find_functions(code)
    local functions = {}
    local pos = 1

    while pos <= #code do
        local char = code:byte(pos)

        -- Skip strings
        if char == 34 or char == 39 or long_bracket_at(code, pos) then
            pos = skip_string(code, pos)
            goto continue
        end

        -- Skip comments
        if char == 45 and code:byte(pos + 1) == 45 then
            local line_end = code:find("\n", pos)
            pos = line_end and line_end + 1 or #code + 1
            goto continue
        end

        -- Match: local function name(params)
        -- (^ anchored at pos so find returns absolute positions without allocating
        -- a whole-remainder substring)
        local match_start, match_end, name, params =
            code:find("^local%s+function%s+([%a_][%w_]*)%s*%(([^)]*)%)", pos)
        if match_start then
            local body_start = match_end + 1
            local body_end_pos = find_matching_end(code, body_start)
            if body_end_pos then
                local body = code:sub(body_start, body_end_pos - 4) -- -4 to exclude "end"
                table.insert(functions, {
                    name = name,
                    params = params,
                    body = body,
                    start = match_start,
                    end_pos = body_end_pos,
                    is_local = true,
                    is_recursive = is_recursive(name, body),
                })
                pos = body_end_pos
                goto continue
            end
        end

        -- Match: function name(params)  (global function)
        match_start, match_end, name, params =
            code:find("^function%s+([%a_][%w_]*)%s*%(([^)]*)%)", pos)
        if match_start then
            local body_start = match_end + 1
            local body_end_pos = find_matching_end(code, body_start)
            if body_end_pos then
                local body = code:sub(body_start, body_end_pos - 4)
                table.insert(functions, {
                    name = name,
                    params = params,
                    body = body,
                    start = match_start,
                    end_pos = body_end_pos,
                    is_local = false,
                    is_recursive = is_recursive(name, body),
                })
                pos = body_end_pos
                goto continue
            end
        end

        -- Match: local name = function(params)
        match_start, match_end, name, params =
            code:find("^local%s+([%a_][%w_]*)%s*=%s*function%s*%(([^)]*)%)", pos)
        if match_start then
            local body_start = match_end + 1
            local body_end_pos = find_matching_end(code, body_start)
            if body_end_pos then
                local body = code:sub(body_start, body_end_pos - 4)
                table.insert(functions, {
                    name = name,
                    params = params,
                    body = body,
                    start = match_start,
                    end_pos = body_end_pos,
                    is_local = true,
                    is_recursive = is_recursive(name, body),
                })
                pos = body_end_pos
                goto continue
            end
        end

        pos = pos + 1
        ::continue::
    end

    return functions
end

-- Replace function calls with inlined IIFEs (skip function definitions)
local function inline_calls(code, functions, skip_strings)
    local result = code

    -- Process in reverse order so inner function calls get replaced
    -- when outer function IIFEs are created
    for i = #functions, 1, -1 do
        local func = functions[i]
        if func.is_recursive then
            goto continue
        end

        -- Collect real call sites (skipping strings/comments when present) and
        -- rebuild the result, replacing each call with an inlined IIFE (skipping defs).
        local parts = {}
        local pos = 1
        local calls = collect_calls(result, func.name, skip_strings)
        for _, call in ipairs(calls) do
            local s, e, call_args = call.s, call.e, call.args
            -- Skip matches embedded in a larger identifier (e.g. xfoo(...) is
            -- not a call to foo)
            local prev = result:sub(s - 1, s - 1)
            if prev ~= "" and prev:match("[%w_]") then
                table.insert(parts, result:sub(pos, s))
                pos = s + 1
                goto skip_match
            end
            -- Check if this is a function definition, not a call
            -- Definitions: "function name(" or "local function name(" or "name = function("
            local after_text = result:sub(e + 1, e + 20)
            local is_def = false
            local before_word = result:sub(math.max(1, s - 20), s - 1)
            if before_word:match("function%s*$") then
                is_def = true
            elseif before_word:match("=%s*$") and after_text:match("^%s*function") then
                is_def = true
            end
            if is_def then
                -- This is a definition, keep it as-is
                table.insert(parts, result:sub(pos, e))
            else
                -- This is a call, inline it. Replicate the original pattern's
                -- separator handling: the separator is the earliest non-word
                -- char such that everything between it and the name is
                -- whitespace; that whitespace (matched by %s*) is dropped.
                local back = s - 1
                while back >= pos do
                    local b = result:byte(back)
                    if b == 32 or b == 9 or b == 10 or b == 13 or b == 11 or b == 12 then
                        back = back - 1
                    else
                        break
                    end
                end
                local sep_pos
                if back >= pos and is_ident_byte(result:byte(back)) then
                    -- word char just before the whitespace run (e.g. "my add("):
                    -- the separator is the first whitespace char after it
                    sep_pos = back + 1
                else
                    -- non-word char directly before the whitespace run, or the
                    -- window is all whitespace (anchor at the window start)
                    sep_pos = (back >= pos) and back or pos
                end
                if sep_pos - 1 >= pos then
                    table.insert(parts, result:sub(pos, sep_pos - 1))
                end
                local sep = result:sub(sep_pos, sep_pos)
                local args_inside = call_args:sub(2, -2)
                table.insert(parts, sep .. "(function(" .. func.params .. ")\n" .. func.body .. "\nend)(" .. args_inside .. ")")
            end
            pos = e + 1
            ::skip_match::
        end
        table.insert(parts, result:sub(pos))
        result = table.concat(parts)

        ::continue::
    end

    return result
end

-- Insert `;` before a paren-starting IIFE statement that follows another
-- statement. Luau rejects a statement that starts with `(` when the preceding
-- line ends with an expression (it reads as an argument-list continuation), so
-- the `;` disambiguates it. This runs even when nothing was inlined, because
-- the source itself may contain such IIFE statements.
local function fix_iife_boundaries(result)
    -- Fix adjacent IIFEs: add semicolon between IIFE call and next IIFE
    -- Pattern: )(args)\n(function → )(args);\n(function (handles indented
    -- (function too: Luau rejects a paren-starting statement without a ;)
    -- Note: ([^%w_]) before (%b()) ensures function() (empty param list) is NOT matched
    result = result:gsub("([^%w_])(%b())\n(%s*)(%(function)", function(sep, args, ws, func_start)
        return sep .. args .. ";\n" .. ws .. func_start
    end)

    -- Fix same-line IIFE calls with trailing comments followed by newline: )(args) -- comment\n(function
    result = result:gsub("([^%w_])(%b())(%s*%-%-[^\n]*)(\n%s*)(%(function)", function(sep, args, comment, ws, func_start)
        return sep .. args .. ";" .. comment .. ws .. func_start
    end)
    -- Fix same-line IIFE calls with trailing comments immediately followed by next IIFE: )(args) -- comment(function
    result = result:gsub("([^%w_])(%b())(%s*%-%-[^\n]*)(%(function)", function(sep, args, comment, func_start)
        return sep .. args .. ";" .. comment .. "\n" .. func_start
    end)
    -- Fix same-line IIFE calls without comments: )(args)(function → )(args);(function
    -- Requires non-word char before ( to avoid matching function() (empty param list)
    result = result:gsub("([^%w_])(%b())(%s*)(%(function)", function(sep, args, ws, func_start)
        return sep .. args .. ";" .. ws .. func_start
    end)

    -- Fix any statement followed by an IIFE on the next line
    -- Only add ; when the previous line ends with a statement terminator
    -- (not after { , ( + - * / ^ % = < > ~ : [ which indicate continuation)
    -- Also skip after control flow keywords: then, else, do, repeat, elseif
    -- And skip if line already ends with ; (from adjacent IIFE fix above).
    -- Captures leading whitespace so indented (function is handled too.
    result = result:gsub("([^\n]+)%s*\n(%s*)(%(function)", function(prev_line, indent, func_start)
        local trimmed = prev_line:gsub("%s+$", "")
        -- Skip if line ends with control flow keywords, continuation chars, or already has semicolon
        -- Also skip if line ends with function() (Luau rejects ; after function() empty param list)
        if trimmed:match("then$") or trimmed:match("else$") or trimmed:match("do$") or
           trimmed:match("repeat$") or trimmed:match("elseif%s+.*$") or
           trimmed:match("[{%(+%-%*/%%^~=<>~:%[]%s*$") or trimmed:match(";%s*$") or
           trimmed:match("function%s*%(%)%s*$") then
            return prev_line .. "\n" .. indent .. func_start
        end
        return prev_line .. ";\n" .. indent .. func_start
    end)

    return result
end

-- Remove function definitions from code (replace with empty lines to preserve line numbers)
local function remove_functions(code, functions)
    local result = code
    -- Process in reverse order to maintain offsets
    for i = #functions, 1, -1 do
        local func = functions[i]
        if func.is_recursive then
            goto continue
        end
        local before = result:sub(1, func.start - 1)
        local after = result:sub(func.end_pos)
        -- Preserve newlines to keep line numbers
        local original = result:sub(func.start, func.end_pos - 1)
        local newlines = original:gsub("[^\n]", "")
        result = before .. newlines .. after
        ::continue::
    end
    return result
end

-- AST implementation: local function bindings and call references share identity,
-- so this transform cannot touch strings/comments or shadowed names by accident.
local function process_ast(code, options)
    local root
    if config._ast then
        root = config._ast
    else
        local ok, parsed = Parser.parse(code, options)
        if not ok then return nil end
        root = parsed.root
    end
    local defs, remove_defs = {}, {}
    Ast.each(root, function(node)
        if node.kind == "StatLocalFunction" and node.name and node.func then
            defs[node.name] = node
        end
    end)
    local called = {}
    Ast.each(root, function(node)
        if node.kind == "ExprCall" and node.func and node.func.kind == "ExprLocal" then
            called[node.func["local"]] = true
        end
    end)
    local inline, replaced_defs = {}, {}
    for binding, def in pairs(defs) do
        local recursive = false
        Ast.each(def.func.body, function(node)
            if node.kind == "ExprCall" and node.func and node.func.kind == "ExprLocal"
                and node.func["local"] == binding then recursive = true end
        end)
        if called[binding] and not recursive then inline[binding] = def end
    end
    local target = options and options.target
    if not target then
        target = config.target or "lua"
    end
    if next(inline) == nil then return fix_iife_boundaries(Ast.render(root, { lower_compound = target ~= "luau" })) end
    Ast.rewrite(root, function(node)
        if node.kind == "ExprCall" and node.func and node.func.kind == "ExprLocal" then
            local def = inline[node.func["local"]]
            if def then
                node.func = Ast.group(def.func)
                replaced_defs[def] = true
                remove_defs[def] = true
            end
        end
    end)
    local seen = {}
    local function strip(value)
        if type(value) ~= "table" or seen[value] then return end
        seen[value] = true
        for key, child in pairs(value) do
            if type(child) == "table" then
                if child[1] ~= nil then
                    for i = #child, 1, -1 do
                        local item = child[i]
                        if type(item) == "table" and remove_defs[item] then table.remove(child, i) end
                    end
                end
                strip(child)
            end
        end
    end
    strip(root)
    return fix_iife_boundaries(Ast.render(root, { lower_compound = target ~= "luau" }))
end

function FunctionInliner.process(code, options)
    if type(code) ~= "string" or code:match("^%s*%-%-.*Obfuscated") then return code end
    if type(code) == "string" and not code:match("^%s*%-%-.*Obfuscated") then
        local transformed = process_ast(code, options)
        if transformed then return transformed end
        return code
    end
    if code:match("^%s*%-%-.*Obfuscated") then return code end

    -- Find all function definitions
    local functions = find_functions(code)

    if #functions == 0 then
        return fix_iife_boundaries(code)
    end

    -- Count calls for each function; only process functions that are actually called
    -- (exclude function definitions themselves from the count)
    for i = 1, #functions do
        local func = functions[i]
        if func.is_recursive then
            func.call_count = 0
            goto count_continue
        end
        local count = 0
        -- Count real call sites. Uses a plain find (fast); matches inside
        -- strings are harmless overcounts (the definition is re-added only if
        -- still referenced, and inline_calls never touches strings).
        local pos = 1
        local pattern = func.name .. "%s*%("
        while pos <= #code do
            local s = code:find(pattern, pos)
            if not s then break end
            -- Skip matches embedded in a larger identifier (e.g. xfoo() is not
            -- a call to foo)
            local prev = code:sub(s - 1, s - 1)
            if prev == "" or not prev:match("[%w_]") then
                -- Check if this is a "function name(" definition
                local before_text = code:sub(math.max(1, s - 10), s - 1)
                if not before_text:match("function%s*$") then
                    count = count + 1
                end
            end
            pos = s + 1
        end
        func.call_count = count
        ::count_continue::
    end

    -- Skip shadowed names: if a name appears in more than one function
    -- definition, the inliner cannot tell which scope a call site belongs to,
    -- so inlining any of them could corrupt the other scope. Leave all such
    -- functions untouched.
    local name_freq = {}
    for _, f in ipairs(functions) do
        name_freq[f.name] = (name_freq[f.name] or 0) + 1
    end

    -- Filter to only functions that are actually called (and not shadowed)
    local called_functions = {}
    for i = 1, #functions do
        local f = functions[i]
        if f.call_count and f.call_count > 0 and name_freq[f.name] == 1 then
            table.insert(called_functions, f)
        end
    end

    if #called_functions == 0 then
        return fix_iife_boundaries(code)
    end

    -- Remove original function definitions first (to avoid matching them as calls)
    local result = remove_functions(code, called_functions)

    -- String/comment skipping is only needed if a string or comment can appear
    -- anywhere in the output (original code or an inlined function body).
    local skip_strings = has_string_or_comment(code)
    if not skip_strings then
        for i = 1, #called_functions do
            if has_string_or_comment(called_functions[i].body) then
                skip_strings = true
                break
            end
        end
    end

    -- Then inline function calls (replace with IIFEs)
    result = inline_calls(result, called_functions, skip_strings)

    -- Re-add definitions for any called function that is still referenced after
    -- inlining. This happens with self-nested calls (f(f(x))) or when a body
    -- calls a function defined later in the source: the inner call is captured
    -- inside an IIFE before that function's own pass runs, so its definition
    -- removal would leave a dangling reference. Prepending the definition keeps
    -- the output correct (slightly less aggressive only in those edge cases).
    -- Local names are forward-declared so re-inserted functions may reference
    -- each other regardless of insertion order. Detected in a single pass.
    local called_names = {}
    for i = 1, #called_functions do
        called_names[called_functions[i].name] = true
    end
    local referenced = {}
    for word in result:gmatch("[%a_][%w_]*") do
        if called_names[word] then referenced[word] = true end
    end
    local prefix_vars = {}
    local prefix_defs = {}
    local inserted = {}
    local changed = true
    while changed do
        changed = false
        for i = 1, #called_functions do
            local func = called_functions[i]
            if referenced[func.name] and not inserted[func.name] then
                inserted[func.name] = true
                -- a re-inserted body may reference more called functions
                for word in func.body:gmatch("[%a_][%w_]*") do
                    if called_names[word] and not referenced[word] then
                        referenced[word] = true
                        changed = true
                    end
                end
                if func.is_local then
                    table.insert(prefix_vars, func.name)
                    table.insert(prefix_defs, func.name .. " = function(" .. func.params .. ")\n" .. func.body .. "\nend")
                else
                    table.insert(prefix_defs, "function " .. func.name .. "(" .. func.params .. ")\n" .. func.body .. "\nend")
                end
            end
        end
    end
    if #prefix_defs > 0 then
        local header = (#prefix_vars > 0) and ("local " .. table.concat(prefix_vars, ", ") .. "\n") or ""
        result = header .. table.concat(prefix_defs, "\n\n") .. "\n\n" .. result
    end

    return fix_iife_boundaries(result)
end

return FunctionInliner
