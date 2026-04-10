-- constants.lua
-- MAX_REGS: registers 0..(MAX_REGS-1) become individual locals in the
-- container function. Registers >= MAX_REGS spill into an overflow table (_R).
--
-- Luau (Roblox) hard limits:
--   200 locals per function scope
--   255 internal bytecode registers per function
--
-- Budget breakdown for the VM container function:
--   4  params:  pos, args, currentUpvalues, detectGcCollect
--   1  local:   returnVar
--  16  locals:  r0..r15  (MAX_REGS register vars)
--   1  local:   _R spill table  (only when maxUsedRegister >= MAX_REGS)
--   3  locals:  _ops, _idx, _s  (chaos/opcode dispatch modes)
--   ──────────────────────────────────────────────────────────────────────
--  25  peak declared registers                         well within 255
--
-- The remaining headroom (~230 registers) is reserved for:
--   • Luau temporary registers during expression evaluation
--   • Upvalue pseudo-instructions emitted by CLOSURE opcodes
--   • do...end scope fences (see emit.lua) free temps between init and loop
--
-- MAX_REGS_MUL: multiplied by MAX_REGS to get the threshold below which
-- register IDs are chosen randomly (for obfuscation). Must be >= 1 so the
-- random-allocation path is reachable. Setting it to 0 broke randomisation
-- and caused registers to always be allocated sequentially from 0.
return {
    MAX_REGS     = 16,
    MAX_REGS_MUL = 1,
}
