-- Dump engine lookup results in a TSV format for parity.py.
-- Usage: luajit test/parity_dump.lua <dict_dir> <words_file>
package.path = "./?.lua;" .. package.path
local engine_mod = require("engine")

local dir, words_file = arg[1], arg[2]
assert(dir and words_file, "usage: parity_dump.lua <dict_dir> <words_file>")

local words = {}
for w in io.lines(words_file) do
    words[#words + 1] = w
end

local e = engine_mod.new{ dict_dirs = { dir }, cache_dir = "/tmp" }
local results, reason = e:lookup_words(words)
if not results then
    io.stderr:write("engine deferred: " .. tostring(reason) .. "\n")
    os.exit(2)
end

local esc = { ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" }
for wi, per in ipairs(results) do
    for _, r in ipairs(per) do
        io.write(string.format("%d\t%s\t%s\t%s\n", wi,
            r.dict, r.word, (r.definition:gsub("[\\\n\t\r]", esc))))
    end
end
