local engine_mod = require("engine")

local function new_engine()
    -- both fixture dicts in one "data dir" tree: pass the parent so the
    -- recursive .ifo scan finds dz/ and plain/
    return engine_mod.new{ dict_dirs = { T.fixture_dir }, cache_dir = "/tmp" }
end

T.add("engine: lookup across dicts with per-word result arrays", function()
    local e = new_engine()
    local res, err = e:lookup_words({ "apples", "cat", "nosuch" })
    assert(res, err)
    T.eq(#res, 3, "one result array per input word")
    T.eq(#res[1], 1)
    T.eq(res[1][1].dict, "Fixture fixture h")
    T.eq(res[1][1].word, "apple")
    T.eq(#res[2], 1)
    T.eq(res[2][1].dict, "Fixture fixture x")
    T.eq(#res[3], 0)
end)

T.add("engine: dict_names filters and orders dictionaries", function()
    local e = new_engine()
    -- only the x dict enabled: 'apples' must find nothing
    local res = assert(e:lookup_words({ "apples", "cat" }, { "Fixture fixture x" }))
    T.eq(#res[1], 0)
    T.eq(#res[2], 1)
    -- unknown names are skipped like sdcv skips unknown -u values
    local res2 = assert(e:lookup_words({ "cat" }, { "No Such Dict", "Fixture fixture x" }))
    T.eq(#res2[1], 1)
    -- empty dict_names behaves like nil (sdcv without -u uses all dicts)
    local res3 = assert(e:lookup_words({ "cat" }, {}))
    T.eq(#res3[1], 1)
end)

T.add("engine: special query characters defer to sdcv", function()
    local e = new_engine()
    local res, reason = e:lookup_words({ "ca*t" })
    T.eq(res, nil, "glob chars are sdcv regex territory")
    assert(reason, "must give a reason")
    T.eq(e:lookup_words({ "/fuzzy" }), nil)
    T.eq(e:lookup_words({ "|data" }), nil)
    -- a backslash is also special in sdcv's analyze_query
    T.eq(e:lookup_words({ "back\\slash" }), nil)
end)

T.add("engine: broken dict is quarantined, call defers once", function()
    local e = new_engine()
    assert(e:lookup_words({ "cat" })) -- loads dicts
    -- simulate a dict whose lookup explodes
    local victim
    for _, d in ipairs(e.dicts) do
        if d.bookname == "Fixture fixture h" then victim = d end
    end
    victim.lookup = function() error("simulated corruption") end
    local res, reason = e:lookup_words({ "cat" })
    T.eq(res, nil, "call with broken dict defers to sdcv")
    assert(reason:match("simulated corruption"), reason)
    T.eq(victim.supported, false, "broken dict quarantined")
    -- subsequent calls with the remaining dict named explicitly still work
    local res2 = assert(e:lookup_words({ "cat" }, { "Fixture fixture x" }))
    T.eq(#res2[1], 1)
    -- but unfiltered calls keep deferring (a dict the user enabled is broken)
    T.eq(e:lookup_words({ "cat" }), nil)
end)

T.add("engine: build_all and status", function()
    local e = new_engine()
    assert(e:build_all())
    local st = e:status()
    T.eq(#st, 2)
    for _, s in ipairs(st) do
        T.eq(s.supported, true)
        T.eq(s.ready, true)
    end
end)

T.add("engine: rebuild_all clears quarantine and rebuilds caches", function()
    local e = new_engine()
    assert(e:lookup_words({ "cat" })) -- loads dicts
    local victim
    for _, d in ipairs(e.dicts) do
        if d.bookname == "Fixture fixture h" then victim = d end
    end
    local cache_file = victim:cache_path()
    victim.lookup = function() error("transient failure") end
    T.eq(e:lookup_words({ "cat" }), nil, "quarantined call defers")
    T.eq(victim.supported, false)
    assert(e:rebuild_all())
    -- after rebuild, the dict set is re-loaded from disk: quarantine cleared
    local res = assert(e:lookup_words({ "apples" }))
    T.eq(#res[1], 1)
    T.eq(res[1][1].word, "apple")
    local f = io.open(cache_file, "rb")
    assert(f, "sidecar cache rebuilt")
    f:close()
end)

T.add("engine: empty dict dir defers to sdcv", function()
    local tmp = os.tmpname()
    os.remove(tmp)
    os.execute(string.format("mkdir -p %q", tmp))
    local e = engine_mod.new{ dict_dirs = { tmp }, cache_dir = "/tmp" }
    local res, reason = e:lookup_words({ "cat" })
    T.eq(res, nil, "no dicts must defer")
    assert(reason, "must give a reason")
    os.execute(string.format("rmdir %q", tmp))
end)
