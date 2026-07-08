local dictzip = require("dictzip")

-- ground truth: rebuild the uncompressed .dict content exactly like make_fixture.py
-- (sorted by stardict key; definitions concatenated). We read it via Python-generated
-- fixture metadata instead: decompress whole file through the reader and compare
-- against gzip CLI output.
local dz_path = T.fixture_dir .. "/dz/fixture.dict.dz"

local function whole_plain()
    local p = io.popen(string.format("gzip -dc %q", dz_path))
    local data = p:read("*a")
    p:close()
    return data
end

T.add("dictzip: open ok", function()
    local r, err = dictzip.open(dz_path)
    T.eq(err, nil)
    assert(r, "no reader")
    r:close()
end)

T.add("dictzip: full-content parity with gzip -dc", function()
    local plain = whole_plain()
    local r = assert(dictzip.open(dz_path))
    T.eq(r:read(0, #plain), plain, "whole-file read differs")
    r:close()
end)

T.add("dictzip: chunk-spanning and boundary reads", function()
    local plain = whole_plain()
    local r = assert(dictzip.open(dz_path))
    -- chlen is 64: these spans cross chunk boundaries
    T.eq(r:read(60, 10), plain:sub(61, 70), "span 60..69")
    T.eq(r:read(0, 1), plain:sub(1, 1), "first byte")
    T.eq(r:read(64, 64), plain:sub(65, 128), "exactly chunk 2")
    T.eq(r:read(#plain - 5, 5), plain:sub(-5), "tail")
    -- repeated read (cache path)
    T.eq(r:read(60, 10), plain:sub(61, 70), "repeat read")
    r:close()
end)

T.add("dictzip: rejects non-dictzip files", function()
    local r, err = dictzip.open(T.fixture_dir .. "/dz/fixture.idx")
    T.eq(r, nil)
    assert(err ~= nil, "expected an error message")
end)

T.add("dictzip: rejects gzip without RA subfield (plain gzip)", function()
    -- build a plain gzip file (no FEXTRA) from the fixture idx
    local src = T.fixture_dir .. "/dz/fixture.idx"
    local dst = os.tmpname() .. ".gz"
    os.execute(string.format("gzip -c %q > %q", src, dst))
    local r, err = dictzip.open(dst)
    T.eq(r, nil)
    assert(err ~= nil, "expected an error message")
    os.remove(dst)
end)

T.add("dictzip: rejects gzip with FEXTRA but no RA subfield", function()
    -- Construct a gzip file with FEXTRA but no RA subfield (some other subfield instead)
    local dst = os.tmpname() .. ".gz"
    local f = io.open(dst, "wb")

    -- gzip header with FEXTRA flag
    f:write("\x1f\x8b")          -- magic
    f:write("\x08")              -- compression method (deflate)
    f:write("\x04")              -- flags: FEXTRA (0x04)
    f:write("\x00\x00\x00\x00")  -- mtime
    f:write("\x00")              -- xfl
    f:write("\x00")              -- os

    -- FEXTRA field: xlen=8, subfield XX (not RA), len=4
    f:write("\x08\x00")          -- xlen (little-endian)
    f:write("XX")                -- SI1, SI2 (not 'RA')
    f:write("\x04\x00")          -- len (little-endian, 4 bytes)
    f:write("\x00\x00\x00\x00")  -- 4 bytes of data

    -- Minimal deflate data (just a single empty block)
    f:write("\x03\x00")          -- uncompressed block: BFINAL=1, BTYPE=00
    f:close()

    local r, err = dictzip.open(dst)
    T.eq(r, nil)
    assert(err ~= nil, "expected an error message")
    os.remove(dst)
end)
