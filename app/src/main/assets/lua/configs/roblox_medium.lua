-- ============================================================
-- KREYZI OBFUSCATOR - MEDIUM CONFIG
-- ============================================================
-- Performance: ⚡⚡⚡⚡🌑 (Fast, 5-10% overhead)
-- Difficulty:  🛡️🛡️🛡️🛡️🌑 (Hard - BVM + constants + opaque predicates)
-- Output Size: 📦📦 Medium (~4-6x original)
--
-- Best for: Production scripts needing strong protection
-- with minimal performance impact. Adds constant array
-- extraction, opaque predicates, and dead code injection.
-- ============================================================

return {
    LuaVersion    = "LuaU",
    VarNamePrefix = "",
    NameGenerator = "MangledShuffled",
    PrettyPrint   = true,
    Seed          = 0,

    Steps = {
        -- Step 1: Normalize Roblox patterns
        {
            Name = "RobloxInstanceTransformer",
            Settings = {
                NormalizeMethodCalls = true,
                SplitRequireChains   = true,
                ExplicitNilInit      = true,
            }
        },
        -- Step 2: Guard Destroy()
        {
            Name = "LuauSanitizer",
            Settings = {
                GuardDestroy = true,
            }
        },
        -- Step 3: Compile to BVM bytecode
        {
            Name = "BvmStep",
            Settings = {
                ChunkSize         = 300,   -- Compact mode
                ObfuscateDispatch = false,
                SeedRng           = true,
            }
        },
        -- Step 4: Encrypt strings with stronger algorithm
        {
            Name = "EncryptStrings",
            Settings = {
                Mode = "XorShiftRotate",
            }
        },
        -- Step 5: Move numeric constants to shared array
        {
            Name = "ConstantArray",
            Settings = {
                MinReferences = 2,
            }
        },
        -- Step 6: Inject opaque predicates (always-true/false branches)
        {
            Name = "OpaquePredicates",
            Settings = {
                Density = 0.15,          -- 15% of control flow gets fake branches
                Complexity = "Medium",
            }
        },
        -- Step 7: Add dead code (unreachable junk instructions)
        {
            Name = "DeadCodeInjector",
            Settings = {
                Density = 0.10,          -- 10% dead code
            }
        },
        -- Step 8: Wrap in function with anti-tamper checks
        {
            Name = "WrapInFunction",
            Settings = {}
        },
        -- Step 9: Output padding for file size obfuscation
        {
            Name = "OutputPadding",
            Settings = {
                MinSize = 50000,         -- Pad to at least 50KB
            }
        },
    },
}
