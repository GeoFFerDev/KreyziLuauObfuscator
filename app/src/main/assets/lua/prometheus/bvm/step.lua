-- ============================================================
--  bvm/step.lua
--  Prometheus Pipeline Step: BvmStep
--
--  Drop this into your Prometheus pipeline config as:
--
--    local BvmStep = require("prometheus.bvm.step")
--    prometheus:apply({BvmStep:new()}, ast)
--
--  Or add it alongside other steps:
--    Steps = { "EncryptStrings", "BvmStep" }
--
--  What this step does:
--    1. Calls ISA.randomize() to produce a fresh polymorphic
--       opcode map for THIS run.
--    2. Instantiates the BVM Compiler and compiles the AST
--       into a proto tree (bytecode + constant pools).
--    3. Instantiates the BVM Emitter and serializes the proto
--       tree + opcode map into a complete standalone Lua script.
--    4. Re-parses the emitted Lua source back into a Prometheus
--       AST (via the Prometheus parser) and returns it so the
--       rest of the pipeline (e.g. EncryptStrings, ConstantArray)
--       can do additional post-processing passes on top.
--
--  Settings:
--    ChunkSize   (number, default 50)
--      Number of table-assignment statements per do...end fence.
--      Lower values → more fences → safer for very large scripts.
--      Higher values → fewer blocks → slightly smaller output.
--
--    ObfuscateDispatch (boolean, default true)
--      When true, the while-loop dispatcher omits any human-
--      readable opcode-name comments in the output source.
--      Set false for debugging to see "-- OP_MOVE" annotations.
--
--    SeedRng (boolean, default false)
--      When true, seeds math.random with os.time() before calling
--      ISA.randomize(), guaranteeing a different ISA every wall-
--      clock second even if the Lua RNG was already seeded
--      externally.  Leave false if you seed the RNG yourself in
--      your pipeline config.
-- ============================================================

local Step      = require("prometheus.step")
local ISA       = require("prometheus.bvm.isa")
local makeCompiler = require("prometheus.bvm.compiler")
local makeEmitter  = require("prometheus.bvm.emitter")

-- We need the Prometheus parser to re-parse the emitted source
-- so the rest of the pipeline receives a proper AST.
local Parser    = require("prometheus.parser")

local BvmStep   = Step:extend()
BvmStep.Name        = "BvmStep"
BvmStep.Description =
    "Compiles the entire script into a polymorphic-ISA bytecode VM. " ..
    "No original Lua source logic appears in the output — only an " ..
    "opaque numeric bytecode array, an encrypted constant pool, " ..
    "and a while-loop VM dispatcher whose opcode IDs are randomized " ..
    "on every obfuscation run (polymorphic ISA)."

BvmStep.SettingsDescriptor = {
    ChunkSize = {
        type    = "number",
        default = 50,
        min     = 10,
        max     = 999999,
    },
    ObfuscateDispatch = {
        type    = "boolean",
        default = true,
    },
    SeedRng = {
        type    = "boolean",
        default = false,
    },
}

function BvmStep:init(_) end

-- ── apply(ast) → new AST ───────────────────────────────────────────────────
function BvmStep:apply(ast)
    -- 1. Optionally re-seed the RNG for guaranteed polymorphism.
    if self.SeedRng then
        math.randomseed(os.time())
    end

    -- 2. Randomize the ISA for this run (with opcode aliasing).
    local op, opname, op_aliases = ISA.randomize()

    -- 3. Compile AST → proto tree.
    local compiler   = makeCompiler(op)
    local all_protos, root_idx = compiler:compile(ast)

    -- 4. Emit proto tree → Lua source string.
    local emitter    = makeEmitter(op, opname, op_aliases, self.ChunkSize)
    local lua_source = emitter:emit(all_protos, root_idx)

    -- ==========================================================
    -- ROBLOX ENVIRONMENT PATCH — INLINE-OPTIMIZATION SAFE
    --
    -- DO NOT use setfenv() — it breaks Inline optimization in
    -- Roblox executors and can cause the VM dispatcher to hang.
    --
    -- The BVM emitter already handles environment resolution
    -- internally via _ENV_ref which checks getgenv(), _ENV, _G
    -- in the correct order.  No prepend needed.
    -- ==========================================================

    -- 5. Re-parse the emitted source into a fresh Prometheus AST.
    --    This allows subsequent pipeline steps (EncryptStrings,
    --    ConstantArray, OpaquePredicates, etc.) to continue
    --    processing the VM wrapper layer.
    local parser  = Parser:new()
    local new_ast = parser:parse(lua_source)

    -- ==========================================================
    -- PROTECT BVM INTERNAL NAMES FROM RENAMING
    -- The pipeline's rename step runs AFTER BvmStep and will
    -- rename ALL variables. If _type gets renamed to 't' and
    -- _ENV_ref gets renamed to 'm', these collide with bytecode
    -- register temps and break the VM at runtime.
    -- We traverse ALL scopes and mark BVM-internal names as
    -- undeclarable (skipIdLookup) so the renamer skips them.
    -- ==========================================================
    if new_ast then
        local BVM_PROTECTED_NAMES = {
            -- Builtin captures
            "_type", "_pairs", "_unpack", "_exec",
            -- VM state
            "Stack", "pc", "top", "open_upvals",
            -- RK decoder
            "rk", "CBIAS",
            -- Register accessors
            "setr", "getr",
            -- String decoder
            "_rgs",
            -- Global resolver
            "_ENV_ref", "_ge",
            -- BVM closure fields
            "_bvmc", "_bvmu", "_bvmv",
            -- Proto data tables
            "_K", "_BC", "_PM", "_SK",
            -- Root upvalue
            "_root_upv",
        }

        local function protectScope(scope)
            if scope.variables and scope.skipIdLookup then
                for id, name in pairs(scope.variables) do
                    for _, protected in ipairs(BVM_PROTECTED_NAMES) do
                        if name == protected then
                            scope.skipIdLookup[id] = true
                            break
                        end
                    end
                end
            end
            if scope.children then
                for _, child in ipairs(scope.children) do
                    protectScope(child)
                end
            end
        end

        protectScope(new_ast.globalScope)
    end

    return new_ast
end

return BvmStep