-- transform_codec.lua
-- Compile-time invertible affine transform pipeline for opcode ID encoding.
-- Uses only +, -, *, % for full Lua 5.1 / 5.2 / Luau compatibility.
-- All arithmetic stays within 2^49 to guarantee exact double-precision results.
--
-- Architecture:
--   encode: id → Layer1 → Layer2 → ... → LayerN → encoded_id
--   decode: encoded_id → LayerN_inv → ... → Layer1_inv → id
--
-- Each layer: encode(x) = (x * A + B) % MOD
--             decode(y) = ((y - B + MOD) * A_inv) % MOD
-- where A is odd (coprime with MOD = 2^24), guaranteeing invertibility.

local TransformCodec = {}
TransformCodec.__index = TransformCodec

-- MOD = 2^24 = 16777216
-- Safe because: max intermediate = (2 * MOD - 1) * A_inv < (2 * 2^24) * 2^24 = 2^49 < 2^53
local MOD = 16777216

-- Extended GCD: returns gcd, x such that a*x ≡ gcd (mod m)
local function extgcd(a, b)
    if b == 0 then return a, 1 end
    local g, x = extgcd(b, a % b)
    return g, x - math.floor(a / b) * x  -- NOTE: intentional re-use of x below
end

-- Full extended GCD returning (g, s, t) where a*s + b*t = g
local function extgcd_full(a, b)
    if b == 0 then return a, 1, 0 end
    local g, s, t = extgcd_full(b, a % b)
    return g, t, s - math.floor(a / b) * t
end

-- Modular inverse of a mod m. Requires gcd(a, m) = 1.
local function modInverse(a, m)
    local g, x, _ = extgcd_full(a % m, m)
    assert(g == 1, "modInverse: a and m must be coprime (got gcd=" .. g .. ")")
    return ((x % m) + m) % m
end

-- Generate a single random affine layer.
-- Returns a table with { A, B, A_inv, MOD, encode(x), decode(y) }
local function newAffineLayer()
    -- A must be odd to be coprime with MOD=2^24
    -- Range [4097, 16383] keeps intermediate products tight
    local A = math.random(2049, 8191) * 2 + 1  -- odd, range [4099, 16383]
    local B = math.random(0, MOD - 1)
    local A_inv = modInverse(A, MOD)

    return {
        A     = A,
        B     = B,
        A_inv = A_inv,
        MOD   = MOD,
        encode = function(x)
            return (x * A + B) % MOD
        end,
        decode = function(y)
            return ((y - B + MOD) * A_inv) % MOD
        end,
    }
end

-- Create a new codec pipeline with `depth` layers (default 3).
-- Returns a TransformCodec object with encode(id) / decode(id) / buildDecodeExpr(posExpr, Ast).
function TransformCodec.new(depth)
    depth = depth or 3
    local layers = {}
    for i = 1, depth do
        layers[i] = newAffineLayer()
    end

    local self = setmetatable({}, TransformCodec)
    self.layers = layers
    self.depth  = depth
    self.MOD    = MOD
    return self
end

-- Encode a real block ID through all layers (compile-time).
function TransformCodec:encode(id)
    local x = id % MOD  -- clamp to MOD range
    for i = 1, self.depth do
        x = self.layers[i].encode(x)
    end
    return x
end

-- Decode back (for testing; NOT emitted into generated code in PolyVmify).
function TransformCodec:decode(encoded)
    local x = encoded
    for i = self.depth, 1, -1 do
        x = self.layers[i].decode(x)
    end
    return x
end

-- Build an AST expression tree for the runtime decode of `posExpr`.
-- Applies layers in reverse: Layer_N_inv → ... → Layer_1_inv.
-- Returns an Ast expression node.
--
-- Generated code shape for depth=3:
--   ((((pos - B3 + MOD) * A3_inv) % MOD - B2 + MOD) * A2_inv) % MOD - B1 + MOD) * A1_inv) % MOD
--
-- This is used by KeyedVmify (where K is subtracted first), not PolyVmify
-- (which encodes IDs at compile time and needs no runtime decode).
function TransformCodec:buildDecodeExpr(posExpr, Ast)
    local expr = posExpr
    for i = self.depth, 1, -1 do
        local L = self.layers[i]
        -- expr = ((expr - B + MOD) * A_inv) % MOD
        expr = Ast.ModExpression(
            Ast.MulExpression(
                Ast.AddExpression(
                    Ast.SubExpression(expr, Ast.NumberExpression(L.B)),
                    Ast.NumberExpression(L.MOD)),
                Ast.NumberExpression(L.A_inv)),
            Ast.NumberExpression(L.MOD))
    end
    return expr
end

-- Build an AST expression for the runtime ENCODE of `idExpr` (used by KeyedVmify
-- to emit pos = (encode(next_id) + K) % MOD style expressions if needed).
function TransformCodec:buildEncodeExpr(idExpr, Ast)
    local expr = idExpr
    for i = 1, self.depth do
        local L = self.layers[i]
        -- expr = (expr * A + B) % MOD
        expr = Ast.ModExpression(
            Ast.AddExpression(
                Ast.MulExpression(expr, Ast.NumberExpression(L.A)),
                Ast.NumberExpression(L.B)),
            Ast.NumberExpression(L.MOD))
    end
    return expr
end

-- Self-test (call during development/debug)
function TransformCodec:selfTest(n)
    n = n or 1000
    for _ = 1, n do
        local id = math.random(0, MOD - 1)
        local enc = self:encode(id)
        local dec = self:decode(enc)
        if dec ~= id then
            return false, ("Roundtrip failed: id=%d enc=%d dec=%d"):format(id, enc, dec)
        end
    end
    return true
end

return TransformCodec
