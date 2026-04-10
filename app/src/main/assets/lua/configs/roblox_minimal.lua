-- ============================================================
-- KREYZI OBFUSCATOR - MINIMAL CONFIG (SMALLEST OUTPUT)
-- ============================================================
-- Performance: ⚡⚡⚡⚡⚡ (Near-native, 1-2x overhead)
-- Difficulty:  🛡️🛡️🌑🌑🌑 (Basic BVM only)
-- Output Size: 📦 Smallest possible (~1.5-2x original)
--
-- Best for: When file size matters most. Minimal obfuscation
-- with maximum performance. Removes all extra steps.
-- ============================================================

return {
    LuaVersion    = "LuaU",
    VarNamePrefix = "",
    NameGenerator = "MangledShuffled",
    PrettyPrint   = true,
    Seed          = 0,

    Steps = {
        -- Step 1: Normalize Roblox patterns (REQUIRED for compatibility)
        {
            Name = "RobloxInstanceTransformer",
            Settings = {
                NormalizeMethodCalls = false,  -- Skip to save space
                SplitRequireChains   = false,  -- Skip to save space
                ExplicitNilInit      = false,  -- Skip to save space
            }
        },
        -- Step 2: Guard Destroy() (REQUIRED to prevent crashes)
        {
            Name = "LuauSanitizer",
            Settings = {
                GuardDestroy = true,
            }
        },
        -- Step 3: Compile to BVM bytecode (CORE obfuscation)
        {
            Name = "BvmStep",
            Settings = {
                ChunkSize         = 999999,  -- MAX density
                ObfuscateDispatch = false,
                SeedRng           = true,
            }
        },
        -- NO other steps - this is the minimal config!
    },
}
