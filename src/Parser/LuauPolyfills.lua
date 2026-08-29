local M = {}

local b = buffer
if not b then
    b = {}

    local function ensure_room(buf, offset)

        while #buf < offset + 1 do
            buf[#buf + 1] = 0
        end
    end

    function b.create(size)
        local buf = {}
        local n = size or 0
        for _ = 1, n do
            buf[#buf + 1] = 0
        end
        return buf
    end

    function b.fromstring(s)
        local buf = {}
        for i = 1, #s do
            buf[i] = string.byte(s, i)
        end
        return buf
    end

    function b.readu8(buf, offset)
        return buf[offset + 1] or 0
    end

    function b.readu16(buf, offset)
        local lo = buf[offset + 1] or 0
        local hi = buf[offset + 2] or 0
        return lo + hi * 256
    end

    function b.readu32(buf, offset)
        local v = 0
        for i = 0, 3 do
            v = v + (buf[offset + 1] or 0) * (256 ^ i)
            offset = offset + 1
        end
        return v
    end

    function b.readstring(buf, offset, length)
        local parts = {}
        for i = 1, length do
            local byte = buf[offset + 1] or 0
            parts[#parts + 1] = string.char(byte)
            offset = offset + 1
        end
        return table.concat(parts)
    end

    function b.writeu8(buf, offset, value)
        ensure_room(buf, offset)
        buf[offset + 1] = value % 256
    end

    function b.writeu16(buf, offset, value)
        ensure_room(buf, offset)
        ensure_room(buf, offset + 1)
        buf[offset + 1] = value % 256
        buf[offset + 2] = math.floor(value / 256) % 256
    end

    buffer = b
end

if not vector then
    vector = {}

    function vector.create(x, y)
        return { x = x, y = y, X = x, Y = y }
    end
end

if not table.freeze then

    function table.freeze(t)
        return t
    end
end

if not table.isfrozen then
    function table.isfrozen()
        return false
    end
end

if not table.create then
    function table.create(count, value)
        local t = {}
        if count and count > 0 then
            if type(value) == "function" then
                for _ = 1, count do
                    t[#t + 1] = value()
                end
            elseif value ~= nil then
                for _ = 1, count do
                    t[#t + 1] = value
                end
            end
        end
        return t
    end
end

if not table.clone then
    function table.clone(t)
        local copy = {}
        for k, v in next, t do
            copy[k] = v
        end
        return copy
    end
end

return M
