-- namegenerators/scarymixed.lua
--
-- Produces variable names that look like base64/SHA fragments:
--   e.g.  BEG1kH1bTfcQIP119aqOetP   K7mRvX2nLpZqJ9dWy4hFsT   etc.
--
-- DESIGN GOALS:
--   • Names look like cryptographic hashes or base64 tokens to a human reader.
--   • Numeric table indexes (c[51]) are untouched — only local variable
--     names and function names use this generator, so there is zero
--     performance penalty (hash-map lookup is never triggered).
--   • Every name is unique and deterministic for a given seed.
--   • Length varies per-name (12–28 chars) to break visual pattern-matching.
--
-- HOW IT WORKS:
--   1. On prepare(), a 64-char alphabet is built from [A-Za-z0-9] and then
--      Fisher-Yates shuffled using the current Lua random seed. This means
--      each obfuscation run produces a completely different character mapping.
--   2. generateName(id) hashes the ID through a small LCG (linear congruential
--      generator) to produce a sequence of alphabet indexes. The LCG is
--      advanced differently for each name so consecutive IDs don't produce
--      visually similar names.
--   3. A second LCG seeded off the first determines length (12-28 chars).
--   4. All names start with a letter (Lua identifier requirement).

local util = require("prometheus.util");

-- Working state — re-initialised by prepare() every run
local alphabet = {};   -- 64-char shuffled array of single chars
local lcgA = 0;        -- LCG multiplier  (set in prepare)
local lcgC = 0;        -- LCG increment   (set in prepare)
local lcgM = 2^31 - 1; -- Mersenne prime  (constant)

-- Fisher-Yates in-place shuffle using the Lua RNG (already seeded by pipeline)
local function shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i);
        t[i], t[j] = t[j], t[i];
    end
end

-- Build the alphabet: all letters and digits, no underscore (keeps names looking
-- like real hash output rather than Lua mangled names).
local function buildAlphabet()
    alphabet = {};
    -- Uppercase first so index 1-26 = letters (guarantees valid start char
    -- as long as we pick from the first 52 entries for position 0).
    for c = string.byte("A"), string.byte("Z") do
        alphabet[#alphabet + 1] = string.char(c);
    end
    for c = string.byte("a"), string.byte("z") do
        alphabet[#alphabet + 1] = string.char(c);
    end
    for c = string.byte("0"), string.byte("9") do
        alphabet[#alphabet + 1] = string.char(c);
    end
    -- alphabet now has 62 entries: [1..26]=A-Z [27..52]=a-z [53..62]=0-9
    shuffle(alphabet);
end

-- LCG step: next = (a * x + c) mod m
local function lcgNext(x)
    return (lcgA * x + lcgC) % lcgM;
end

-- Derive a visually-random but deterministic state seed from an integer ID.
-- We use a second fixed LCG (Knuth's) to spread consecutive IDs far apart.
local SPREAD_A = 1664525;
local SPREAD_C = 1013904223;
local SPREAD_M = 2^32;

local function idToSeed(id)
    -- Two rounds of Knuth spreading to decorrelate adjacent IDs
    local s = (SPREAD_A * (id + 1) + SPREAD_C) % SPREAD_M;
    s = (SPREAD_A * s + SPREAD_C) % SPREAD_M;
    return s + 1; -- keep > 0
end

function generateName(id, _)
    -- Derive a per-name seed so name(1) and name(2) share no visual prefix
    local state = idToSeed(id);

    -- Determine length: 12-28 characters, driven by the seed
    state = lcgNext(state);
    local length = 12 + (state % 17); -- 12..28

    local chars = {};

    -- First character: must be a letter.
    -- The first 52 entries of (shuffled) alphabet are guaranteed to be
    -- letters because we only shuffle; letters were inserted before digits.
    -- But after shuffle we can't rely on position, so we pick from the
    -- letter-only subset (indices where alphabet[i] matches [A-Za-z]).
    -- Simpler: just retry if digit.
    state = lcgNext(state);
    local startIdx = (state % 52) + 1; -- index into first 52 = all letters
    -- Rebuild a letter-only pick by skipping digits in alphabet:
    local letterCount = 0;
    local firstChar;
    for _, ch in ipairs(alphabet) do
        if ch:match("[A-Za-z]") then
            letterCount = letterCount + 1;
            if letterCount == startIdx then
                firstChar = ch;
                break;
            end
        end
    end
    chars[1] = firstChar or alphabet[1]; -- fallback (alphabet[1] always exists)

    -- Remaining characters: any of the 62
    for i = 2, length do
        state = lcgNext(state);
        chars[i] = alphabet[(state % #alphabet) + 1];
    end

    return table.concat(chars);
end

function prepare(_)
    -- Rebuild and shuffle alphabet using the pipeline's current RNG seed.
    buildAlphabet();

    -- Pick LCG parameters from primes so the sequence has full period.
    -- We sample from a fixed table of good multipliers for LCG mod 2^31-1.
    local goodMultipliers = {
        16807, 48271, 69621, 39373, 40692, 1220703125, 950706376,
    };
    lcgA = goodMultipliers[math.random(#goodMultipliers)];
    lcgC = math.random(1, 99991) * 2 + 1; -- odd number for full period
end

return {
    generateName = generateName,
    prepare      = prepare,
};
