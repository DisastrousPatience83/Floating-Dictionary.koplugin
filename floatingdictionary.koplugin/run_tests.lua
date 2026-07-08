-- Standalone test harness for FastDict pure modules.
-- Usage: cd plugins/fastdict.koplugin && $LUAJIT test/run_tests.lua $SCRATCH/fixture
package.path = "./?.lua;" .. package.path

T = { tests = {}, fixture_dir = arg[1] or error("usage: run_tests.lua <fixture_dir>") }

function T.add(name, fn)
    T.tests[#T.tests + 1] = { name = name, fn = fn }
end

function T.eq(got, expected, msg)
    if got ~= expected then
        error(string.format("%s\n  expected: %q\n  got:      %q",
            msg or "not equal", tostring(expected), tostring(got)), 2)
    end
end

function T.run()
    local failed = 0
    for _, t in ipairs(T.tests) do
        local ok, err = pcall(t.fn)
        if ok then
            io.write("PASS ", t.name, "\n")
        else
            failed = failed + 1
            io.write("FAIL ", t.name, "\n  ", tostring(err), "\n")
        end
    end
    io.write(string.format("%d/%d passed\n", #T.tests - failed, #T.tests))
    os.exit(failed == 0 and 0 or 1)
end

-- test files register into T; added in later tasks:
for _, mod in ipairs({ "test_dictzip", "test_stardict", "test_engine" }) do
    local ok, err = pcall(dofile, "test/" .. mod .. ".lua")
    if not ok and not tostring(err):match("No such file") and not tostring(err):match("cannot open") then
        error(err)
    end
end

T.run()
