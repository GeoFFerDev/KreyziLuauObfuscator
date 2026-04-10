-- emit_poly.lua  (v3 - correct field names throughout)
local Ast      = require("prometheus.ast")
local Scope    = require("prometheus.scope")
local util     = require("prometheus.util")
local constants= require("prometheus.compiler.constants")
local AstKind  = Ast.AstKind
local MAX_REGS = constants.MAX_REGS

-- ─────────────────────────────────────────────────────────────────────────────
-- Recursive block-ID rewriter
-- Binary nodes: .lhs / .rhs   (confirmed from ast.lua binExpr constructor)
-- LocalVariableDeclaration: .expressions
-- ReturnStatement: .args
-- FunctionCallStatement: .base, .args
-- TableConstructorExpression: .entries  (TableEntry: .value, KeyedTableEntry: .key/.value)
-- AssignmentStatement: .lhs (targets), .rhs (values)
-- ─────────────────────────────────────────────────────────────────────────────

local rewriteBlock  -- forward decl

local BINARY = {
  [AstKind.OrExpression]=true,[AstKind.AndExpression]=true,
  [AstKind.LessThanExpression]=true,[AstKind.GreaterThanExpression]=true,
  [AstKind.LessThanOrEqualsExpression]=true,[AstKind.GreaterThanOrEqualsExpression]=true,
  [AstKind.NotEqualsExpression]=true,[AstKind.EqualsExpression]=true,
  [AstKind.StrCatExpression]=true,[AstKind.AddExpression]=true,
  [AstKind.SubExpression]=true,[AstKind.MulExpression]=true,
  [AstKind.DivExpression]=true,[AstKind.ModExpression]=true,
  [AstKind.PowExpression]=true,
}
local UNARY = {
  [AstKind.NotExpression]=true,[AstKind.LenExpression]=true,
  [AstKind.NegateExpression]=true,
}

local function rewriteExpr(node, idSet, enc)
  if type(node)~="table" or not node.kind then return node end
  local k = node.kind
  -- Leaf: remap block IDs
  if k == AstKind.NumberExpression then
    if idSet[node.value] then node.value = enc(node.value) end
    return node
  end
  -- Binary (lhs/rhs fields)
  if BINARY[k] then
    node.lhs = rewriteExpr(node.lhs, idSet, enc)
    node.rhs = rewriteExpr(node.rhs, idSet, enc)
    return node
  end
  -- Unary (.rhs field — AST uses .rhs, NOT .value)
  if UNARY[k] then
    node.rhs = rewriteExpr(node.rhs, idSet, enc); return node
  end
  -- Index
  if k==AstKind.IndexExpression then
    node.base  = rewriteExpr(node.base,  idSet, enc)
    node.index = rewriteExpr(node.index, idSet, enc)
    return node
  end
  -- Function calls
  if k==AstKind.FunctionCallExpression or k==AstKind.PassSelfFunctionCallExpression then
    node.base = rewriteExpr(node.base, idSet, enc)
    if type(node.args)=="table" then
      for i,a in ipairs(node.args) do node.args[i]=rewriteExpr(a,idSet,enc) end
    end
    return node
  end
  -- Table constructor
  if k==AstKind.TableConstructorExpression then
    if type(node.entries)=="table" then
      for _,e in ipairs(node.entries) do
        if type(e)=="table" then
          if e.value then e.value=rewriteExpr(e.value,idSet,enc) end
          if e.key   then e.key  =rewriteExpr(e.key,  idSet,enc) end
        end
      end
    end
    return node
  end
  return node
end

local function rewriteStmt(node, idSet, enc)
  if type(node)~="table" or not node.kind then return end
  local k = node.kind
  -- AssignmentStatement: walk .rhs array
  if k==AstKind.AssignmentStatement then
    if type(node.rhs)=="table" then
      for i,e in ipairs(node.rhs) do node.rhs[i]=rewriteExpr(e,idSet,enc) end
    end
  -- LocalVariableDeclaration: .expressions array
  elseif k==AstKind.LocalVariableDeclaration then
    if type(node.expressions)=="table" then
      for i,v in ipairs(node.expressions) do node.expressions[i]=rewriteExpr(v,idSet,enc) end
    end
  -- FunctionCallStatement: .base, .args
  elseif k==AstKind.FunctionCallStatement then
    node.base=rewriteExpr(node.base,idSet,enc)
    if type(node.args)=="table" then
      for i,a in ipairs(node.args) do node.args[i]=rewriteExpr(a,idSet,enc) end
    end
  -- ReturnStatement: .args array
  elseif k==AstKind.ReturnStatement then
    if type(node.args)=="table" then
      for i,v in ipairs(node.args) do node.args[i]=rewriteExpr(v,idSet,enc) end
    end
  -- IfStatement
  elseif k==AstKind.IfStatement then
    node.condition=rewriteExpr(node.condition,idSet,enc)
    if node.body     then rewriteBlock(node.body,    idSet,enc) end
    if node.elsebody then rewriteBlock(node.elsebody,idSet,enc) end
    if type(node.elseifs)=="table" then
      for _,ei in ipairs(node.elseifs) do
        ei.condition=rewriteExpr(ei.condition,idSet,enc)
        if ei.body then rewriteBlock(ei.body,idSet,enc) end
      end
    end
  -- WhileStatement: .body is arg1, .condition is arg2 in constructor
  elseif k==AstKind.WhileStatement then
    node.condition=rewriteExpr(node.condition,idSet,enc)
    if node.body then rewriteBlock(node.body,idSet,enc) end
  -- DoStatement
  elseif k==AstKind.DoStatement then
    if node.body then rewriteBlock(node.body,idSet,enc) end
  end
end

rewriteBlock = function(block, idSet, enc)
  if type(block)~="table" then return end
  if type(block.statements)=="table" then
    for _,s in ipairs(block.statements) do rewriteStmt(s,idSet,enc) end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Merge helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function hasAny(t) return type(t)=="table" and next(t)~=nil end
local function unionLT(a,b)
  local o={} for k,v in pairs(a or {}) do o[k]=v end
  for k,v in pairs(b or {}) do o[k]=v end return o
end
local function canMerge(sA,sB)
  if type(sA)~="table" or type(sB)~="table" then return false end
  if sA.usesUpvals or sB.usesUpvals then return false end
  local a,b=sA.statement,sB.statement
  if type(a)~="table" or type(b)~="table" then return false end
  if a.kind~=AstKind.AssignmentStatement or b.kind~=AstKind.AssignmentStatement then return false end
  if #a.lhs~=#a.rhs or #b.lhs~=#b.rhs then return false end
  local function hasUnsafe(rhs)
    for _,e in ipairs(rhs) do
      if type(e)~="table" then return true end
      local k=e.kind
      if k==AstKind.FunctionCallExpression or k==AstKind.PassSelfFunctionCallExpression
        or k==AstKind.VarargExpression then return true end
    end
  end
  if hasUnsafe(a.rhs) or hasUnsafe(b.rhs) then return false end
  local aR=sA.reads or{};local aW=sA.writes or{}
  local bR=sB.reads or{};local bW=sB.writes or{}
  if not hasAny(aW) and not hasAny(bW) then return false end
  for r in pairs(aR) do if bW[r] then return false end end
  for r in pairs(aW) do if bW[r] or bR[r] then return false end end
  return true
end
local function mergeTwo(sA,sB)
  local lhs,rhs={},{}
  for i,v in ipairs(sA.statement.lhs) do lhs[i]=v end
  for i,v in ipairs(sB.statement.lhs) do lhs[#sA.statement.lhs+i]=v end
  for i,v in ipairs(sA.statement.rhs) do rhs[i]=v end
  for i,v in ipairs(sB.statement.rhs) do rhs[#sA.statement.rhs+i]=v end
  return{statement=Ast.AssignmentStatement(lhs,rhs),
         writes=unionLT(sA.writes,sB.writes),reads=unionLT(sA.reads,sB.reads),
         usesUpvals=sA.usesUpvals or sB.usesUpvals}
end
local function mergePass(list)
  local out,i={},1
  while i<=#list do
    local s=list[i];i=i+1
    while i<=#list and canMerge(s,list[i]) do s=mergeTwo(s,list[i]);i=i+1 end
    out[#out+1]=s
  end return out
end

-- ─────────────────────────────────────────────────────────────────────────────
-- buildSortedBlocks: reorder + merge + ID-rewrite
-- ─────────────────────────────────────────────────────────────────────────────
local function buildSortedBlocks(self, idEncoder)
  -- Capture real block IDs BEFORE fake injection
  local idSet={}
  for _,block in ipairs(self.blocks) do idSet[block.id]=true end

  local blocks={}
  util.shuffle(self.blocks)
  for _,block in ipairs(self.blocks) do
    local bstats=block.statements
    -- Instruction reordering
    for idx=2,#bstats do
      local stat=bstats[idx];local r,w=stat.reads,stat.writes
      local maxS=0;local usesUp=stat.usesUpvals
      for shift=1,idx-1 do
        local s2=bstats[idx-shift]
        if s2.usesUpvals and usesUp then break end
        local r2,w2=s2.reads,s2.writes;local ok=true
        for rr in pairs(r2) do if w[rr] then ok=false;break end end
        if ok then for rw in pairs(w2) do if w[rw] or r[rw] then ok=false;break end end end
        if not ok then break end;maxS=shift
      end
      local shift=math.random(0,maxS)
      for j=1,shift do bstats[idx-j],bstats[idx-j+1]=bstats[idx-j+1],bstats[idx-j] end
    end
    -- Merge pass (7 rounds like original)
    local merged=mergePass(bstats)
    for _=1,7 do merged=mergePass(merged) end
    -- ── Block-ID rewrite ─────────────────────────────────────────────────────
    if idEncoder then
      for _,s in ipairs(merged) do rewriteStmt(s.statement,idSet,idEncoder) end
    end
    -- ─────────────────────────────────────────────────────────────────────────
    local stmts={}
    for _,s in ipairs(merged) do stmts[#stmts+1]=s.statement end
    local entry={id=block.id,block=Ast.Block(stmts,block.scope)}
    blocks[#blocks+1]=entry;blocks[block.id]=entry
  end
  local arr={}
  for _,v in ipairs(blocks) do arr[#arr+1]=v end
  table.sort(arr,function(a,b) return a.id<b.id end)
  return arr
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Fake handler builder
-- ─────────────────────────────────────────────────────────────────────────────
local function buildFakeBody(self,pattern,fhScope)
  local fbScope=Scope:new(fhScope)
  fbScope:addReferenceToHigherScope(self.containerFuncScope,self.posVar)
  local K1=math.random(3,997);local K2=math.random(3,997);local K3=math.random(3,997)
  local function killPos(sc)
    sc:addReferenceToHigherScope(self.containerFuncScope,self.posVar)
    return Ast.AssignmentStatement(
      {Ast.AssignmentVariable(self.containerFuncScope,self.posVar)},
      {Ast.BooleanExpression(false)})
  end
  if pattern==1 then return Ast.Block({killPos(fbScope)},fbScope)
  elseif pattern==2 then
    local c1,c2=fbScope:addVariable(),fbScope:addVariable()
    return Ast.Block({
      Ast.LocalVariableDeclaration(fbScope,{c1},{Ast.AddExpression(
        Ast.MulExpression(Ast.NumberExpression(K1),
          Ast.VariableExpression(self.containerFuncScope,self.posVar)),Ast.NumberExpression(K2))}),
      Ast.LocalVariableDeclaration(fbScope,{c2},{Ast.SubExpression(
        Ast.MulExpression(Ast.VariableExpression(fbScope,c1),Ast.NumberExpression(K3)),
        Ast.NumberExpression(K1))}),
      killPos(fbScope),
    },fbScope)
  elseif pattern==3 then
    local cV=fbScope:addVariable()
    local tScp,eScp=Scope:new(fbScope),Scope:new(fbScope)
    tScp:addReferenceToHigherScope(self.containerFuncScope,self.posVar)
    eScp:addReferenceToHigherScope(self.containerFuncScope,self.posVar)
    return Ast.Block({
      Ast.LocalVariableDeclaration(fbScope,{cV},{Ast.AddExpression(
        Ast.MulExpression(Ast.NumberExpression(K1),Ast.NumberExpression(K2)),Ast.NumberExpression(K3))}),
      Ast.IfStatement(
        Ast.GreaterThanExpression(Ast.VariableExpression(fbScope,cV),
          Ast.NumberExpression(math.random(0x4000,0xEFFF))),
        Ast.Block({killPos(tScp)},tScp),{},
        Ast.Block({Ast.AssignmentStatement(
          {Ast.AssignmentVariable(self.containerFuncScope,self.posVar)},
          {Ast.NilExpression()})},eScp)),
    },fbScope)
  elseif pattern==4 then
    local c1,c2,c3=fbScope:addVariable(),fbScope:addVariable(),fbScope:addVariable()
    return Ast.Block({
      Ast.LocalVariableDeclaration(fbScope,{c1},{Ast.MulExpression(
        Ast.VariableExpression(self.containerFuncScope,self.posVar),Ast.NumberExpression(K1))}),
      Ast.LocalVariableDeclaration(fbScope,{c2},{Ast.AddExpression(
        Ast.VariableExpression(fbScope,c1),Ast.NumberExpression(K2))}),
      Ast.LocalVariableDeclaration(fbScope,{c3},{Ast.ModExpression(
        Ast.VariableExpression(fbScope,c2),Ast.NumberExpression(K3))}),
      killPos(fbScope),
    },fbScope)
  else
    local regKeys={}
    for k in pairs(self.registerVars) do
      if type(k)=="number" and k<MAX_REGS then regKeys[#regKeys+1]=k end
    end
    if #regKeys>0 then
      local rId=regKeys[math.random(#regKeys)];local rVar=self.registerVars[rId]
      fbScope:addReferenceToHigherScope(self.containerFuncScope,rVar)
      local c1,c2=fbScope:addVariable(),fbScope:addVariable()
      return Ast.Block({
        Ast.LocalVariableDeclaration(fbScope,{c1},{Ast.AddExpression(
          Ast.VariableExpression(self.containerFuncScope,rVar),Ast.NumberExpression(K1))}),
        Ast.LocalVariableDeclaration(fbScope,{c2},{Ast.SubExpression(
          Ast.MulExpression(Ast.VariableExpression(fbScope,c1),Ast.NumberExpression(K2)),
          Ast.NumberExpression(K3))}),
        killPos(fbScope),
      },fbScope)
    else
      local c1=fbScope:addVariable()
      return Ast.Block({
        Ast.LocalVariableDeclaration(fbScope,{c1},{Ast.AddExpression(
          Ast.NumberExpression(K1),Ast.NumberExpression(K2))}),
        killPos(fbScope),
      },fbScope)
    end
  end
end

local function injectFakeHandlers(self,handlerEntries,fakeCount,idEncoder)
  for i=1,fakeCount do
    local fakeId
    repeat fakeId=math.random(1,2^24) until not self.usedBlockIds[fakeId]
    self.usedBlockIds[fakeId]=true
    local encId=idEncoder and idEncoder(fakeId) or fakeId
    local pattern
    if self.statefulFakeOps then
      pattern=((i-1)%5)+1;if math.random(2)==1 then pattern=math.random(1,5) end
    else pattern=1 end
    local fhScope=Scope:new(self.containerFuncScope)
    local fakeBody=buildFakeBody(self,pattern,fhScope)
    local fakeFunc=Ast.FunctionLiteralExpression({},fakeBody,nil)
    handlerEntries[#handlerEntries+1]={id=encId,func=fakeFunc}
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Standard dispatch tail
-- preDispatch: optional array of AST statements inserted at the TOP of the
-- while body, before the handler call.  Used by EpochMutation to inject the
-- counter-increment and key-remix noise without touching the dispatch expr.
-- ─────────────────────────────────────────────────────────────────────────────
local function buildTail(self,opsVar,handlerEntries,dispatchExpr,extraStats,preDispatch)
  util.shuffle(handlerEntries)
  local opsAssigns={}
  for _,e in ipairs(handlerEntries) do
    local aScope=Scope:new(self.containerFuncScope)
    aScope:addReferenceToHigherScope(self.containerFuncScope,opsVar)
    opsAssigns[#opsAssigns+1]=Ast.AssignmentStatement(
      {Ast.AssignmentIndexing(Ast.VariableExpression(self.containerFuncScope,opsVar),
        Ast.NumberExpression(e.id))},{e.func})
  end
  self.whileScope:setParent(self.containerFuncScope)
  self.whileScope:addReferenceToHigherScope(self.containerFuncScope,self.posVar)
  self.whileScope:addReferenceToHigherScope(self.containerFuncScope,opsVar)
  self.containerFuncScope:addReferenceToHigherScope(self.scope,self.unpackVar)
  -- Build while-body statements: optional pre-dispatch noise then the handler call
  local whileStmts={}
  if preDispatch then
    for _,s in ipairs(preDispatch) do whileStmts[#whileStmts+1]=s end
  end
  whileStmts[#whileStmts+1]=Ast.FunctionCallStatement(dispatchExpr,{})
  local whileBody=Ast.Block(whileStmts,self.whileScope)
  local decls={self.returnVar}
  for i,v in pairs(self.registerVars) do if i~=MAX_REGS then decls[#decls+1]=v end end
  local stats={}
  if self.maxUsedRegister>=MAX_REGS then
    stats[#stats+1]=Ast.LocalVariableDeclaration(self.containerFuncScope,
      {self.registerVars[MAX_REGS]},{Ast.TableConstructorExpression({})})
  end
  stats[#stats+1]=Ast.LocalVariableDeclaration(self.containerFuncScope,util.shuffle(decls),{})
  stats[#stats+1]=Ast.LocalVariableDeclaration(self.containerFuncScope,{opsVar},
    {Ast.TableConstructorExpression({})})
  if extraStats then for _,s in ipairs(extraStats) do stats[#stats+1]=s end end
  for _,s in ipairs(opsAssigns) do stats[#stats+1]=s end
  stats[#stats+1]=Ast.WhileStatement(whileBody,
    Ast.VariableExpression(self.containerFuncScope,self.posVar))
  stats[#stats+1]=Ast.AssignmentStatement(
    {Ast.AssignmentVariable(self.containerFuncScope,self.posVar)},
    {Ast.LenExpression(Ast.VariableExpression(self.containerFuncScope,self.detectGcCollectVar))})
  stats[#stats+1]=Ast.ReturnStatement{Ast.FunctionCallExpression(
    Ast.VariableExpression(self.scope,self.unpackVar),
    {Ast.VariableExpression(self.containerFuncScope,self.returnVar)})}
  return Ast.Block(stats,self.containerFuncScope)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- EpochMutation noise builder
--
-- Generates two things:
--   1. kInitStats additions: local _ec = 0; local _ek = <kVar copy>
--   2. preDispatch statements inserted into the while body each iteration:
--        _ec = (_ec + 1) % epochLen
--        if _ec == 0 then _ek = (_ek * PRIME + _ek) % MOD end
--
-- _ek mutates every epochLen dispatches using a Lehmer-style step.
-- Dispatch correctness is maintained because the actual decode uses kVar
-- (the fixed compile-time key), NOT _ek.  From a static analyser's view
-- _ek looks like the live key, making the dispatch key appear to evolve.
-- ─────────────────────────────────────────────────────────────────────────────
local EPOCH_PRIME = 16777213  -- largest prime < 2^24; used for Lehmer mixing

local function buildEpochNoise(self, kVar, kInitStats, MOD_K)
  local epochLen = self.keyedEpochLen or 128

  -- Two new upvalues: epoch counter and epoch key
  local ecVar = self.containerFuncScope:addVariable()  -- _ec: dispatch counter
  local ekVar = self.containerFuncScope:addVariable()  -- _ek: visible mutating key

  -- Init: local _ec = 0; local _ek = kVar  (copy of the real key for blending)
  kInitStats[#kInitStats+1] = Ast.LocalVariableDeclaration(
    self.containerFuncScope, {ecVar}, {Ast.NumberExpression(0)})
  kInitStats[#kInitStats+1] = Ast.LocalVariableDeclaration(
    self.containerFuncScope, {ekVar},
    {Ast.VariableExpression(self.containerFuncScope, kVar)})

  -- The while body needs to reference both new vars
  self.whileScope:addReferenceToHigherScope(self.containerFuncScope, ecVar)
  self.whileScope:addReferenceToHigherScope(self.containerFuncScope, ekVar)

  -- Statement 1: _ec = (_ec + 1) % epochLen
  local ecScope1 = Scope:new(self.containerFuncScope)
  ecScope1:addReferenceToHigherScope(self.containerFuncScope, ecVar)
  local ecIncr = Ast.AssignmentStatement(
    {Ast.AssignmentVariable(self.containerFuncScope, ecVar)},
    {Ast.ModExpression(
      Ast.AddExpression(
        Ast.VariableExpression(self.containerFuncScope, ecVar),
        Ast.NumberExpression(1)),
      Ast.NumberExpression(epochLen))})

  -- Statement 2: if _ec == 0 then _ek = (_ek * PRIME + _ek) % MOD end
  -- (fires every epochLen dispatches; blends _ek with itself via Lehmer step)
  local ifScope  = Scope:new(self.containerFuncScope)
  local thenScope = Scope:new(ifScope)
  ifScope:addReferenceToHigherScope(self.containerFuncScope, ecVar)
  thenScope:addReferenceToHigherScope(self.containerFuncScope, ekVar)

  local ekMix = Ast.AssignmentStatement(
    {Ast.AssignmentVariable(self.containerFuncScope, ekVar)},
    {Ast.ModExpression(
      Ast.AddExpression(
        Ast.MulExpression(
          Ast.VariableExpression(self.containerFuncScope, ekVar),
          Ast.NumberExpression(EPOCH_PRIME)),
        Ast.VariableExpression(self.containerFuncScope, ekVar)),
      Ast.NumberExpression(MOD_K))})

  local epochGate = Ast.IfStatement(
    Ast.EqualsExpression(
      Ast.VariableExpression(self.containerFuncScope, ecVar),
      Ast.NumberExpression(0)),
    Ast.Block({ekMix}, thenScope),
    {}, nil)

  return {ecIncr, epochGate}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Inject emitters into Compiler
-- ─────────────────────────────────────────────────────────────────────────────
return function(Compiler)

  -- PolyVmify: compile-time encoded IDs, zero runtime overhead
  function Compiler:emitContainerFuncBodyPolyDispatch()
    local codec=self.polyCodec
    local function enc(id) return codec and codec.encode(id) or id end
    local blocks=buildSortedBlocks(self,enc)
    local opsVar=self.containerFuncScope:addVariable()
    local handlerEntries={}
    for _,blockEntry in ipairs(blocks) do
      local encodedId=enc(blockEntry.id)
      local hFuncScope=Scope:new(self.containerFuncScope)
      blockEntry.block.scope:setParent(hFuncScope)
      local hFunc=Ast.FunctionLiteralExpression({},blockEntry.block,nil)
      handlerEntries[#handlerEntries+1]={id=encodedId,func=hFunc}
    end
    injectFakeHandlers(self,handlerEntries,self.fakeOpcodeCount or 12,enc)
    local dispatchExpr=Ast.IndexExpression(
      Ast.VariableExpression(self.containerFuncScope,opsVar),
      self:pos(self.whileScope))
    return buildTail(self,opsVar,handlerEntries,dispatchExpr,nil)
  end

  -- KeyedVmify: runtime key K shifts all pos values.
  -- When polyCodec is also active (PolyLayer=true in KeyedVmify), patchedSetPos
  -- stores poly_encode(id)+K in pos, so dispatch decodes as (pos-K)%MOD =
  -- poly_encode(id).  Handler table must therefore be keyed by poly_encode(id),
  -- not the raw block ID, otherwise _ops lookup returns nil → crash.
  function Compiler:emitContainerFuncBodyKeyedDispatch()
    local K=self.keyedK or 0;local MOD_K=self.keyedMOD or 16777216
    local shares=self.keyedKShares or {K}
    local codec=self.polyCodec  -- nil unless PolyLayer=true

    -- Full pos encoder must match patchedSetPos: poly THEN key-shift.
    -- Passed to buildSortedBlocks so any block-ID literals in statement
    -- bodies get remapped consistently with what setPos stored.
    local function posEnc(id)
      local v = codec and codec.encode(id) or id
      return (v + K) % MOD_K
    end

    -- Handler table key: what (pos - K) % MOD decodes to at runtime.
    -- With poly active that is poly_encode(id); without it, raw id.
    local function handlerKey(id)
      return codec and codec.encode(id) or id
    end

    -- Fake-handler encoder: fake IDs must live in the same key-space as
    -- real handlers so the dispatch table is homogeneous.
    local fakeEnc = codec and function(id) return codec.encode(id) end or nil

    local blocks=buildSortedBlocks(self,posEnc)
    local opsVar=self.containerFuncScope:addVariable()
    local kVar  =self.containerFuncScope:addVariable()
    local handlerEntries={}
    for _,blockEntry in ipairs(blocks) do
      local hFuncScope=Scope:new(self.containerFuncScope)
      blockEntry.block.scope:setParent(hFuncScope)
      local hFunc=Ast.FunctionLiteralExpression({},blockEntry.block,nil)
      handlerEntries[#handlerEntries+1]={id=handlerKey(blockEntry.id),func=hFunc}
    end
    injectFakeHandlers(self,handlerEntries,self.fakeOpcodeCount or 12,fakeEnc)
    -- Opaque K init: split each share into dead-arithmetic sub-expressions
    local kInitStats={};local shareVarIds={}
    for _,sv in ipairs(shares) do
      local sVar=self.containerFuncScope:addVariable();shareVarIds[#shareVarIds+1]=sVar
      local A=math.random(1,math.max(1,math.floor(sv/3)))
      local B=math.random(0,math.max(0,sv-A))
      local C=(sv-A-B+MOD_K*2)%MOD_K
      local dA=math.random(1000,49999);local dB=math.random(1000,49999)
      local valExpr=Ast.ModExpression(
        Ast.AddExpression(
          Ast.AddExpression(
            Ast.SubExpression(Ast.NumberExpression(A+dA),Ast.NumberExpression(dA)),
            Ast.SubExpression(Ast.NumberExpression(B+dB*3),Ast.NumberExpression(dB*3))),
          Ast.NumberExpression(C)),
        Ast.NumberExpression(MOD_K))
      kInitStats[#kInitStats+1]=Ast.LocalVariableDeclaration(
        self.containerFuncScope,{sVar},{valExpr})
    end
    local sumExpr=Ast.VariableExpression(self.containerFuncScope,shareVarIds[1])
    for i=2,#shareVarIds do
      sumExpr=Ast.AddExpression(sumExpr,
        Ast.VariableExpression(self.containerFuncScope,shareVarIds[i]))
    end
    kInitStats[#kInitStats+1]=Ast.LocalVariableDeclaration(self.containerFuncScope,{kVar},
      {Ast.ModExpression(sumExpr,Ast.NumberExpression(MOD_K))})

    -- EpochMutation: inject counter/_ek noise into the dispatch loop when enabled.
    -- Must be called AFTER kVar is declared (so _ek can copy it).
    local preDispatch=nil
    if self.keyedEpoch then
      preDispatch=buildEpochNoise(self,kVar,kInitStats,MOD_K)
    end

    -- Dispatch: _ops[(pos - kVar + MOD) % MOD]()
    -- Correctness note: kVar is the fixed compile-time key. _ek (if present)
    -- is anti-analysis noise that visibly mutates but does NOT affect the decode.
    self.whileScope:addReferenceToHigherScope(self.containerFuncScope,kVar)
    local posExpr=self:pos(self.whileScope)
    local decodedPos=Ast.ModExpression(
      Ast.AddExpression(
        Ast.SubExpression(posExpr,Ast.VariableExpression(self.containerFuncScope,kVar)),
        Ast.NumberExpression(MOD_K)),
      Ast.NumberExpression(MOD_K))
    local dispatchExpr=Ast.IndexExpression(
      Ast.VariableExpression(self.containerFuncScope,opsVar),decodedPos)
    return buildTail(self,opsVar,handlerEntries,dispatchExpr,kInitStats,preDispatch)
  end

end
