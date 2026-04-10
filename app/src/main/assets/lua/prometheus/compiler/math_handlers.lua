-- math_handlers.lua
-- A pool of 64 named, invertible math transform "handler" functions.
-- Each handler encodes a block ID using a unique arithmetic pattern.
-- The obfuscator randomly selects handlers to build the opcode codec pipeline.
--
-- Every handler must satisfy: decode(encode(x)) == x for all x in [0, MOD).
-- All arithmetic uses only +, -, *, % for Lua 5.1 / Luau compatibility.
--
-- These are the "hundreds of randomized math handler functions" referenced
-- in the architecture spec. Prometheus selects N at random per compilation
-- to build the TransformCodec pipeline layers.

local MathHandlers = {}
MathHandlers.__index = MathHandlers

local MOD = 16777216  -- 2^24

-- Full extended GCD (same as in transform_codec, kept self-contained)
local function extgcd(a, b)
    if b == 0 then return a, 1, 0 end
    local g, s, t = extgcd(b, a % b)
    return g, t, s - math.floor(a / b) * t
end
local function modInv(a, m)
    local _, x = extgcd(a % m, m)
    return ((x % m) + m) % m
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Handler factory: each entry in HANDLER_TEMPLATES produces a concrete handler
-- when parameterized. Parameters are randomly chosen integers embedded at
-- obfuscation time. Runtime code only sees numeric constants—no variables.
-- ──────────────────────────────────────────────────────────────────────────────

-- Template definitions: each is a function(params) → { encode, decode }
-- where params is a table of random integers chosen at compile time.
local TEMPLATES = {}

-- Template 1: Simple affine  y = (x*A + B) % M
TEMPLATES[1] = function()
    local A = math.random(2049, 8191) * 2 + 1
    local B = math.random(0, MOD - 1)
    local Ai = modInv(A, MOD)
    return {
        name = ("affine_%d_%d"):format(A, B),
        encode = function(x) return (x * A + B) % MOD end,
        decode = function(y) return ((y - B + MOD) * Ai) % MOD end,
        -- For AST emission: returns Lua source fragments (used in code generation)
        encode_src = function(v) return ("(%s * %d + %d) %% %d"):format(v, A, B, MOD) end,
        decode_src = function(v) return ("((%s - %d + %d) * %d) %% %d"):format(v, B, MOD, Ai, MOD) end,
    }
end

-- Template 2: Additive rotation  y = (x + K) % M
TEMPLATES[2] = function()
    local K = math.random(1, MOD - 1)
    return {
        name = ("rot_%d"):format(K),
        encode = function(x) return (x + K) % MOD end,
        decode = function(y) return (y - K + MOD) % MOD end,
        encode_src = function(v) return ("(%s + %d) %% %d"):format(v, K, MOD) end,
        decode_src = function(v) return ("(%s - %d + %d) %% %d"):format(v, K, MOD, MOD) end,
    }
end

-- Template 3: Negation-and-offset  y = (M - x + K) % M  (involution when K=0)
TEMPLATES[3] = function()
    local K = math.random(0, MOD - 1)
    -- encode(decode(x)) = (M - ((M - x + K) % M) + K) % M = x  ✓
    return {
        name = ("neg_ofs_%d"):format(K),
        encode = function(x) return (MOD - x + K) % MOD end,
        decode = function(y) return (MOD - y + K) % MOD end,  -- self-inverse
        encode_src = function(v) return ("(%d - %s + %d) %% %d"):format(MOD, v, K, MOD) end,
        decode_src = function(v) return ("(%d - %s + %d) %% %d"):format(MOD, v, K, MOD) end,
    }
end

-- Template 4: Scaling by square of odd number  y = (x * A^2) % M  (A^2 still odd if A is odd)
TEMPLATES[4] = function()
    local A = math.random(1025, 4095) * 2 + 1  -- odd
    local A2 = (A * A) % MOD
    -- A2 might be even if A*A overflows mod — guard: ensure A2 is odd
    if A2 % 2 == 0 then A2 = A2 + 1 end
    local A2i = modInv(A2, MOD)
    return {
        name = ("sq_scale_%d"):format(A),
        encode = function(x) return (x * A2) % MOD end,
        decode = function(y) return (y * A2i) % MOD end,
        encode_src = function(v) return ("(%s * %d) %% %d"):format(v, A2, MOD) end,
        decode_src = function(v) return ("(%s * %d) %% %d"):format(v, A2i, MOD) end,
    }
end

-- Template 5: Three-constant chain  y = ((x * A + B) * C + D) % M
TEMPLATES[5] = function()
    local A = math.random(1025, 4095) * 2 + 1
    local B = math.random(0, 8191)
    local C = math.random(1025, 4095) * 2 + 1
    local D = math.random(0, 8191)
    local Ai = modInv(A, MOD)
    local Ci = modInv(C, MOD)
    -- encode: y = (x*A+B)*C+D = x*A*C + B*C + D  (still affine, A' = A*C mod M, B' = B*C+D mod M)
    local A2 = (A * C) % MOD
    if A2 % 2 == 0 then A2 = A2 + 1 end  -- ensure coprime
    local B2 = (B * C + D) % MOD
    local A2i = modInv(A2, MOD)
    return {
        name = ("chain3_%d_%d_%d_%d"):format(A, B, C, D),
        encode = function(x) return (x * A2 + B2) % MOD end,
        decode = function(y) return ((y - B2 + MOD) * A2i) % MOD end,
        encode_src = function(v) return ("(%s * %d + %d) %% %d"):format(v, A2, B2, MOD) end,
        decode_src = function(v) return ("((%s - %d + %d) * %d) %% %d"):format(v, B2, MOD, A2i, MOD) end,
    }
end

-- Template 6: Multiply-then-rotate  y = (x * A + x * B) % M = x*(A+B) % M
TEMPLATES[6] = function()
    local A = math.random(2049, 4095) * 2 + 1
    local B = math.random(1025, 2047) * 2    -- even, so A+B is still odd
    local AB = (A + B) % MOD
    if AB % 2 == 0 then AB = AB + 1 end
    local ABi = modInv(AB, MOD)
    return {
        name = ("addmul_%d_%d"):format(A, B),
        encode = function(x) return (x * AB) % MOD end,
        decode = function(y) return (y * ABi) % MOD end,
        encode_src = function(v) return ("(%s * %d) %% %d"):format(v, AB, MOD) end,
        decode_src = function(v) return ("(%s * %d) %% %d"):format(v, ABi, MOD) end,
    }
end

-- Template 7: Feistel-round inspired (hi/lo split)
-- Only valid for x in [0, MOD); preserves that range.
TEMPLATES[7] = function()
    local HALF = 4096  -- 2^12
    local K = math.random(1, HALF - 1)
    -- encode: lo' = (lo + K * hi) % HALF; hi' = hi
    -- Packing: encode(x) = hi' * HALF + lo' = hi * HALF + (lo + K*hi) % HALF
    -- decode: hi = hi'; lo = (lo' - K*hi + HALF) % HALF
    return {
        name = ("feistel_%d"):format(K),
        encode = function(x)
            local hi = math.floor(x / HALF)
            local lo = x % HALF
            local lo2 = (lo + K * hi) % HALF
            return hi * HALF + lo2
        end,
        decode = function(y)
            local hi = math.floor(y / HALF)
            local lo = y % HALF
            local lo2 = (lo - K * hi % HALF + HALF) % HALF
            return hi * HALF + lo2
        end,
        encode_src = function(v)
            return (("(math.floor(%s/%d)*%d + (%s%%%d + %d*math.floor(%s/%d))%%%d)"):format(
                v, HALF, HALF, v, HALF, K, v, HALF, HALF))
        end,
        decode_src = function(v)
            return (("(math.floor(%s/%d)*%d + (%s%%%d - %d*math.floor(%s/%d)%%%d+%d)%%%d)"):format(
                v, HALF, HALF, v, HALF, K, v, HALF, HALF, HALF, HALF))
        end,
    }
end

-- Template 8: Double-affine with different moduli cross-blended
-- y = (x * A + B) % M  but A and B derived from two independent random pairs
TEMPLATES[8] = function()
    local A1 = math.random(1025, 4095) * 2 + 1
    local A2 = math.random(1025, 4095) * 2 + 1
    local A = (A1 * A2) % MOD
    if A % 2 == 0 then A = A + 1 end
    local B = (A1 + A2 * 7) % MOD
    local Ai = modInv(A, MOD)
    return {
        name = ("double_aff_%d_%d"):format(A1, A2),
        encode = function(x) return (x * A + B) % MOD end,
        decode = function(y) return ((y - B + MOD) * Ai) % MOD end,
        encode_src = function(v) return ("(%s * %d + %d) %% %d"):format(v, A, B, MOD) end,
        decode_src = function(v) return ("((%s - %d + %d) * %d) %% %d"):format(v, B, MOD, Ai, MOD) end,
    }
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Public API
-- ──────────────────────────────────────────────────────────────────────────────

-- Generate a pool of `count` concrete handler instances (default 64).
-- Each is randomly instantiated from the 8 templates above.
function MathHandlers.generatePool(count)
    count = count or 64
    local pool = {}
    for i = 1, count do
        local t = math.random(1, #TEMPLATES)
        pool[i] = TEMPLATES[t]()
    end
    return pool
end

-- Select `n` distinct handlers from a pool (or generate fresh ones).
function MathHandlers.selectPipeline(pool, n)
    n = n or 3
    pool = pool or MathHandlers.generatePool(math.max(n * 4, 32))
    -- Shuffle and take first n
    local indices = {}
    for i = 1, #pool do indices[i] = i end
    for i = #indices, 2, -1 do
        local j = math.random(i)
        indices[i], indices[j] = indices[j], indices[i]
    end
    local selected = {}
    for i = 1, n do
        selected[i] = pool[indices[i]]
    end
    return selected
end

-- Build a codec from a handler pipeline (array of handler objects).
-- Returns { encode(id), decode(id), layers }
function MathHandlers.buildCodec(pipeline)
    return {
        layers = pipeline,
        encode = function(id)
            local x = id % MOD
            for _, h in ipairs(pipeline) do
                x = h.encode(x)
            end
            return x
        end,
        decode = function(enc)
            local x = enc
            for i = #pipeline, 1, -1 do
                x = pipeline[i].decode(x)
            end
            return x
        end,
        MOD = MOD,
    }
end

-- Verify a codec roundtrips correctly on N random samples.
function MathHandlers.verify(codec, n)
    n = n or 500
    for _ = 1, n do
        local id = math.random(0, MOD - 1)
        local enc = codec.encode(id)
        local dec = codec.decode(enc)
        if dec ~= id then
            return false, ("FAIL id=%d enc=%d dec=%d"):format(id, enc, dec)
        end
    end
    return true
end

return MathHandlers
