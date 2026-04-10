return {
    LuaVersion    = "LuaU",
    VarNamePrefix = "",
    NameGenerator = "MangledShuffled",
    PrettyPrint   = true,              -- Multi-line vertical output
    Seed          = 0,               -- 0 = random layout every run

    Steps = {
        -- Step 1: Normalize Roblox patterns at AST level BEFORE BVM compilation.
        -- This eliminates :Destroy() bugs, require() chain corruption,
        -- and ensures clean register allocation inside closures.
        {
            Name = "RobloxInstanceTransformer",
            Settings = {
                NormalizeMethodCalls = true,   -- obj:Destroy() → obj.Destroy(obj)
                SplitRequireChains   = true,   -- require(x).Method(...) → 2 statements
                ExplicitNilInit      = true,   -- local x,y,z → local x=nil,y=nil,z=nil
            }
        },
        -- Step 2: Guard obj:Destroy() calls against nil/function values
        {
            Name = "LuauSanitizer",
            Settings = {
                GuardDestroy = true,
            }
        },
        -- Step 3: Compile to BVM bytecode (now with clean AST)
        {
            Name = "BvmStep",
            Settings = {
                ChunkSize         = 1000,  -- MAX compact mode
                ObfuscateDispatch = false,  -- Must be false: true breaks dispatch key lookup
                SeedRng           = true,   -- New randomized ISA every run
            }
        },
    },
}