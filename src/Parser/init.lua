local Parser = {}
local config = require("config")

require("Parser/LuauPolyfills")

local function resolve_module_path(name)
    local candidates = { name, name .. "/init" }
    for _, cand in ipairs(candidates) do
        local dotted = cand:gsub("%.", "/")
        for pattern in package.path:gmatch("[^;]+") do
            local filename = pattern:gsub("%?", dotted)
            local f = io.open(filename, "rb")
            if f then
                f:close()
                return filename
            end
        end
    end
    return nil
end

local function load_with_env(filename, env)
    local chunk, err
    if _G.setfenv then

        chunk, err = loadfile(filename)
        if chunk then setfenv(chunk, env) end
    else

        chunk, err = loadfile(filename, "t", env)
    end
    return chunk, err
end

local function load_parser_module(module)
    local stdlib = {}
    for _, name in ipairs({
        "tostring", "tonumber", "type", "assert", "error", "pcall", "xpcall",
        "select", "pairs", "ipairs", "next", "rawget", "rawset", "rawequal",
        "setmetatable", "getmetatable", "unpack", "require", "print",
        "string", "math", "table", "os", "utf8", "buffer", "vector",
        "coroutine", "bit32", "_G", "_VERSION",
    }) do
        stdlib[name] = _G[name]
    end
    local env = setmetatable(stdlib, { __index = _G })

    local filename = resolve_module_path(module)
    if not filename then
        error("Cannot resolve module path for " .. module, 2)
    end
    local chunk, err = load_with_env(filename, env)
    if not chunk then
        error("Failed to load " .. module .. ": " .. tostring(err), 2)
    end
    return chunk()
end

require("Parser/LuauPolyfills")

local LuauParser = load_parser_module("Parser/LuauParser/init")
local AstRenderer = require("Parser/AstRenderer")

local PARSER_PRESETS = {
    lua51 = { bitwiseOperators = false },
    lua52 = { bitwiseOperators = false },
    lua53 = { bitwiseOperators = true },
    lua54 = { bitwiseOperators = true },
    luau = { bitwiseOperators = false },
    glua = { bitwiseOperators = false },
}

local function normalize_version(version)
    if version == nil then return nil end
    local value = tostring(version):lower():gsub("%s+", "")
    local aliases = {
        ["5.1"] = "lua51", ["lua5.1"] = "lua51", lua51 = "lua51",
        ["5.2"] = "lua52", ["lua5.2"] = "lua52", lua52 = "lua52",
        ["5.3"] = "lua53", ["lua5.3"] = "lua53", lua53 = "lua53",
        ["5.4"] = "lua54", ["lua5.4"] = "lua54", lua54 = "lua54",
        luau = "luau", glua = "glua",
    }
    return aliases[value]
end

local function resolve_parse_options(options)
    local opts = {}
    for key, value in pairs(options or {}) do opts[key] = value end
    local version = normalize_version(opts.version)
    if version then
        opts.bitwiseOperators = PARSER_PRESETS[version].bitwiseOperators
    elseif opts.bitwiseOperators == nil then
        local target = config.target or "lua"
        if target == "lua" then
            local configured = config.lua_version
            version = normalize_version(configured) or "lua54"
        else
            version = normalize_version(target) or target
        end
        local preset = PARSER_PRESETS[version]
        opts.bitwiseOperators = preset and preset.bitwiseOperators or false
    end
    return opts
end

function Parser.parse(source, options)
    if type(source) ~= "string" then
        return false, ("Parser.parse expects a string, got %s"):format(type(source))
    end
    local ok, result = LuauParser.parse(source, resolve_parse_options(options))
    if not ok then
        local firstError = (result and result.errors and result.errors[1])
        local message = firstError and firstError.message or "unknown parse error"
        return false, tostring(message)
    end
    return true, result
end

function Parser.render(ast, options)
    return AstRenderer.render(ast, options or {})
end

function Parser.process(code)
    if type(code) ~= "string" then
        error("Parser.process expects a string", 2)
    end

    return code
end

Parser.LuauParser = LuauParser
Parser.AstRenderer = AstRenderer
Parser.Renderer = require("Parser/LuauRenderer")
Parser.PARSER_PRESETS = PARSER_PRESETS
Parser.resolve_parse_options = resolve_parse_options

return Parser
