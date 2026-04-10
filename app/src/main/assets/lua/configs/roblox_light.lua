-- ============================================================
-- KREYZI OBFUSCATOR - LIGHT CONFIG
-- ============================================================
-- Performance: ⚡⚡⚡⚡⚡ (Fastest, near-native speed)
-- Difficulty:  🛡️🛡️🌑🌑🌑 (Easy - basic BVM + string encoding)
-- Output Size: 📦 Small (~2-3x original)
--
-- Best for: Everyday scripts where speed matters most.
-- Provides basic protection via BVM compilation and
-- polymorphic opcode randomization.
-- ============================================================

return {
    LuaVersion    = "LuaU",
    VarNamePrefix = "",
    NameGenerator = "MangledShuffled",
    PrettyPrint   = false,              -- Multi-line output for readability
    Seed          = 0,                  -- 0 = random every run

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
        -- Step 2: Guard Destroy() calls
        {
            Name = "LuauSanitizer",
            Settings = {
                GuardDestroy = true,
            }
        },
        -- Step 3: Compile to BVM bytecode (polymorphic ISA)
        {
            Name = "BvmStep",
            Settings = {
                ChunkSize         = 999999,   -- Compact mode
                ObfuscateDispatch = false,
                SeedRng           = true,
            }
        },
        -- Step 4: Encrypt string constants
        {
            Name = "EncryptStrings",
            Settings = {
                Mode = "XorShift",
            }
        },
        -- Step 5: Add output padding for anti-tamper
        {
            Name = "OutputPadding",
            Settings = {}
        },
    },
}
