local GarbageCodeInserter = {}
local Parser = require("Parser")
local Ast = require("Parser/Ast")

local LOWERCASE_A, LOWERCASE_Z = 97, 122
local MAX_RANDOM_NUMBER = 100
local MAX_LOOP_COUNT = 10
local VARIABLE_NAME_LENGTH = 6

local function generateRandomVariableName()
    local name = {}
    for i = 1, VARIABLE_NAME_LENGTH do
        table.insert(name, string.char(math.random(LOWERCASE_A, LOWERCASE_Z)))
    end
    return table.concat(name)
end

local function generateRandomNumber(max)
    return math.random(1, max or MAX_RANDOM_NUMBER)
end

local code_types = {
    variable = function()
        return string.format("local %s = %d", generateRandomVariableName(), generateRandomNumber())
    end,
    while_loop = function()
        return string.format("while %s do local _ = %d break end",
            tostring(math.random() > 0.5),
            generateRandomNumber(100)
        )
    end,
    for_loop = function()
        return string.format("for %s = 1, %d do local _ = %d end",
            generateRandomVariableName(),
            generateRandomNumber(MAX_LOOP_COUNT),
            generateRandomNumber()
        )
    end,
    if_statement = function()
        return string.format("if %s then local _ = %d end",
            tostring(math.random() > 0.5),
            generateRandomNumber()
        )
    end,
    function_def = function()
        return string.format("local function %s(%s) local _ = %d end",
            generateRandomVariableName(),
            generateRandomVariableName(),
            generateRandomNumber()
        )
    end
}

local code_type_keys = {}
for k in pairs(code_types) do table.insert(code_type_keys, k) end

local function generateRandomCode()
    return code_types[code_type_keys[math.random(#code_type_keys)]]()
end

local function generateGarbage(blocks, sep)
    sep = sep or "\n"
    local garbage_code = {}
    for i = 1, blocks do
        local code = generateRandomCode()
        if not code:match("while true") and not code:match("for %w+ = %d+, %d+ do local _ = %d+ end") then
            table.insert(garbage_code, code)
        end
    end
    return table.concat(garbage_code, sep)
end

function GarbageCodeInserter.process(code, garbage_blocks)
    if type(code) ~= "string" or #code == 0 then
        error("Input code must be a non-empty string", 2)
    end
    if type(garbage_blocks) ~= "number" then
        error("garbage_blocks must be a number", 2)
    end
    local ok, parsed = Parser.parse(code)
    if not ok then return code end
    local function parse_garbage()
        local chunk = generateGarbage(garbage_blocks)
        local garbage_ok, parsed_garbage = Parser.parse(chunk)
        return garbage_ok and parsed_garbage.root.body or {}
    end
    local prefix, suffix = parse_garbage(), parse_garbage()
    local body = {}
    for _, stat in ipairs(prefix) do body[#body + 1] = stat end
    for _, stat in ipairs(parsed.root.body) do body[#body + 1] = stat end
    for _, stat in ipairs(suffix) do body[#body + 1] = stat end
    return Ast.render(Ast.block(body))
end

function GarbageCodeInserter.setSeed(seed)
    math.randomseed(seed)
end

return GarbageCodeInserter
