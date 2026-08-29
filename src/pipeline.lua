--pipeline.lua
local config = require("config")
local manifest = require("manifest")
local Parser = require("Parser")

-- Load the Parser subsystem eagerly. Its transpiled body snapshots the original
-- standard library into an isolated environment at load time; executing real
-- obfuscated payloads in-process can replace globals (e.g. the Virtual Machine
-- output rebinds `_G.tostring`), so the parser must load before any user code.
require("Parser")

local Watermarker = require("modules/watermark")

local Pipeline = {}

local AST_NATIVE = {
    ["modules/function_inliner"] = true,
    ["modules/StringToExpressions"] = true,
    ["modules/WrapInFunction"] = true,
    ["modules/variable_renamer"] = true,
}

local function is_enabled(method)
    return config.get("settings." .. method.config_key .. ".enabled")
end

local function apply_method(method, code)
    local ok, processor = pcall(require, method.module)
    if not ok then
        error("Failed to load module " .. method.module .. ": " .. tostring(processor))
    end

    local ast_native = AST_NATIVE[method.module]
    if ast_native and not config._ast then
        local ok, parsed = Parser.parse(code)
        if ok then config._ast = parsed.root end
    end
    local result
    if method.process then
        result = method.process(processor, code, config)
    else
        result = processor.process(code)
    end
    if ast_native then
        code = result
    else
        config._ast = nil
        code = result
    end
    return code
end

function Pipeline.process(code)
    config._ast = nil
    for _, method in ipairs(manifest.modules_by_pipeline()) do
        if is_enabled(method) and not manifest.is_incompatible(method, config.target) then
            code = apply_method(method, code)
        end
    end

    -- Watermark is always last and intentionally not exposed as an API bitkey.
    if config.get("settings.watermark_enabled") then
        code = Watermarker.process(code)
    end

    config._ast = nil
    return code
end

return Pipeline
