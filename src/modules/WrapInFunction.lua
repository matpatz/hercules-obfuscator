local Wrapper = {}
local Parser = require("Parser")
local Ast = require("Parser/Ast")
local config = require("config")
function Wrapper.process(code)
    local root = config._ast
    if not root then
        local ok, parsed = Parser.parse(code)
        if not ok then return [[(function(...) ]] .. code .. [[ end)()]] end
        root = parsed.root
    end
    local fn = Ast.function_({}, root.body, true)
    local call = Ast.expr_stat(Ast.call(Ast.group(fn), {}))
    return Ast.render(Ast.block({ call }))
end
return Wrapper
