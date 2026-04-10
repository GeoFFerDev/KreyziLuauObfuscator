-- ============================================================
-- KREYZI OBFUSCATOR - HARD CONFIG (MAXIMUM SECURITY)
-- ============================================================
-- Performance: ⚡⚡⚡🌑🌑 (Good, 10-20% overhead)
-- Difficulty:  🛡️🛡️🛡️🛡️🛡️ (Extreme - nearly impossible to reverse)
-- Output Size: 📦📦📦 Large (~8-12x original)
--
-- Best for: High-value commercial scripts where maximum
-- protection is critical. Uses all available obfuscation
-- layers including StringVault, AntiTamper, AntiHook,
-- RuntimeGuard, and dual-layer VM execution.
-- ============================================================

return {
    LuaVersion    = "LuaU",
    VarNamePrefix = "",
    NameGenerator = "MangledShuffled",
    PrettyPrint   = true,
    Seed          = 0,

    Steps = {
        -- Step 1: Normalize Roblox patterns at AST level
        {
            Name = "RobloxInstanceTransformer",
            Settings = {
                NormalizeMethodCalls = true,
                SplitRequireChains   = true,
                ExplicitNilInit      = true,
            }
        },
        -- Step 2: Guard all dangerous method calls
        {
            Name = "LuauSanitizer",
            Settings = {
                GuardDestroy = true,
            }
        },
        -- Step 3: Compile entire script to BVM bytecode
        {
            Name = "BvmStep",
            Settings = {
                ChunkSize         = 200,   -- Compact mode
                ObfuscateDispatch = false,
                SeedRng           = true,
            }
        },
        -- Step 4: Encrypt ALL strings with multi-layer encryption
        {
            Name = "EncryptStrings",
            Settings = {
                Mode = "MultiLayer",   -- XOR + Shift + Rotate
            }
        },
        -- Step 5: Extract constants to shared pool (hides magic numbers)
        {
            Name = "ConstantArray",
            Settings = {
                MinReferences = 1,
                Shuffle = true,
            }
        },
        -- Step 6: StringVault - compress and encrypt string pool
        {
            Name = "StringVault",
            Settings = {
                Compression = true,
                Encryption = true,
            }
        },
        -- Step 7: Inject opaque predicates (fake control flow)
        {
            Name = "OpaquePredicates",
            Settings = {
                Density = 0.25,          -- 25% fake branches
                Complexity = "High",
            }
        },
        -- Step 8: Dead code injection (junk unreachable code)
        {
            Name = "DeadCodeInjector",
            Settings = {
                Density = 0.20,          -- 20% dead code
                Patterns = "Random",
            }
        },
        -- Step 9: Anti-tamper detection (prevents modification)
        {
            Name = "AntiTamper",
            Settings = {
                CheckHash = true,        -- Runtime integrity check
                CheckSize = true,
            }
        },
        -- Step 10: Anti-hook protection (prevents function hooking)
        {
            Name = "AntiHook",
            Settings = {
                ProtectGlobals = true,
                ProtectMetatables = true,
            }
        },
        -- Step 11: Runtime environment guard
        {
            Name = "RuntimeGuard",
            Settings = {
                CheckExecutor = false,   -- Don't check executor type (compatibility)
                CheckDebug = true,       -- Detect debug mode
            }
        },
        -- Step 12: Wrap everything in nested function layers
        {
            Name = "WrapInFunction",
            Settings = {
                Layers = 2,              -- Double wrapping
            }
        },
        -- Step 13: Output padding (massive file size for confusion)
        {
            Name = "OutputPadding",
            Settings = {
                MinSize = 100000,        -- Pad to at least 100KB
            }
        },
        -- Step 14: Compress bytecode arrays
        {
            Name = "BytecodeCompressor",
            Settings = {
                Level = "High",
            }
        },
    },
}
