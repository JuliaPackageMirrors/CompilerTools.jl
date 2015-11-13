#=
Copyright (c) 2015, Intel Corporation
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
- Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
THE POSSIBILITY OF SUCH DAMAGE.
=#

module LivenessAnalysis

import ..DebugMsg
DebugMsg.init()

using CompilerTools
using CompilerTools.CFGs
using CompilerTools.LambdaHandling

import Base.show

include("function-descriptions.jl")

@doc """
Convenience function to create an Expr and make sure the type is filled in as well.
The first arg is the type of the Expr and the rest of the args are the constructors args to Expr.
"""
function TypedExpr(typ, rest...)
    res = Expr(rest...)
    res.typ = typ
    res
end

export BlockLiveness, find_bb_for_statement, show

type Access
    sym
    read
end

SymGen = Union{Symbol, GenSym}

@doc """
Liveness information for a TopLevelStatement in the CFG.
Contains a pointer to the corresponding CFG TopLevelStatement.
Contains def, use, live_in, and live_out for the current statement.
"""
type TopLevelStatement
    tls :: CFGs.TopLevelStatement

    def      :: Set{SymGen}
    use      :: Set{SymGen}
    live_in  :: Set{SymGen}
    live_out :: Set{SymGen}

    TopLevelStatement(t) = new(t, Set{SymGen}(), Set{SymGen}(), Set{SymGen}(), Set{SymGen}())
end

@doc """
Overload of Base.show to pretty-print a LivenessAnalysis.TopLevelStatement.
"""
function show(io::IO, tls::TopLevelStatement)
    print(io, "TLS ", tls.tls.index)

    print(io, " Def = (")
    for i in tls.def
      print(io, i, " ")
    end
    print(io, ") ")

    print(io, "Use = (")
    for i in tls.use
      print(io, i, " ")
    end
    print(io, ") ")

    print(io, "LiveIn = (")
    for i in tls.live_in
      print(io, i, " ")
    end
    print(io, ") ")

    print(io, "LiveOut = (")
    for i in tls.live_out
      print(io, i, " ")
    end
    print(io, ") ")

    println(io, "Expr: ", tls.tls.expr)
end

@doc """
Sometimes if new AST nodes are introduced then we need to ask for their def and use set as a whole
and then incorporate that into our liveness analysis directly.
"""
type AccessSummary
    def
    use
end

@doc """
Liveness information for a BasicBlock.
Contains a pointer to the corresponding CFG BasicBlock.
Contains def, use, live_in, and live_out for this basic block.
Contains an array of liveness information for the top level statements in this block.
"""
type BasicBlock
    cfgbb :: CFGs.BasicBlock

    def      :: Set{SymGen}
    use      :: Set{SymGen}
    live_in  :: Set{SymGen}
    live_out :: Set{SymGen}

    statements :: Array{TopLevelStatement,1}
 
    BasicBlock(bb) = new(bb, Set{SymGen}(), Set{SymGen}(), Set{SymGen}(), Set{SymGen}(), TopLevelStatement[])
end

@doc """
Overload of Base.show to pretty-print a LivenessAnalysis.BasicBlock.
"""
function show(io::IO, bb::BasicBlock)
    print(io, bb.cfgbb)
    print(io," Defs(")
    for j in bb.def
        print(io, " ", j)
    end
    print(io," ) Uses(")
    for j in bb.use
        print(io, " ", j)
    end
    print(io," ) LiveIn(")
    for j in bb.live_in
        print(io, " ", j)
    end
    print(io," ) LiveOut(")
    for j in bb.live_out
        print(io, " ", j)
    end
    println(io,")")

    tls = bb.statements
    if length(tls) == 0
        println(io,"Basic block without any statements.")
    end
    for j = 1:length(tls)
        if(DEBUG_LVL >= 5)
            print(io, "    ",tls[j].tls.index, "  ", tls[j].tls.expr)
            print(io,"  Defs(")
            for k in tls[j].def
                print(io, " ", k)
            end
            print(io," ) Uses(")
            for k in tls[j].use
                print(io, " ", k)
            end
            print(io," ) LiveIn(")
            for k in tls[j].live_in
                print(io, " ", k)
            end
            print(io," ) LiveOut(")
            for k in tls[j].live_out
                print(io, " ", k)
            end
            print(io," )")
        end
        println(io)
    end
end

@doc """
Called when AST traversal finds some Symbol "sym" in a basic block "bb".
"read" is true if the symbol is being used and false if it is being defined.
"""
function add_access(bb, sym, read)
    dprintln(3,"add_access ", sym, " ", read, " ", typeof(bb), " ")
    if bb == nothing    # If not in a basic block this is dead code so ignore.
        return nothing
    end

    assert(length(bb.statements) != 0)
    tls = bb.statements[end]    # Get the statements to which we will add access information.
    dprintln(3, "tls = ", tls)
    write = !read

    # If this synbol is already in the statement then it is already in the basic block as a whole.
    if in(sym, tls.def)
        dprintln(3, "sym already in tls.def")
        return nothing
    end

    # If the first use is a read then it goes in tls.use.
    # If there is a write after a read then it will be in tls.use and tls.def.
    # If there is a read after a write (which can happen for basic blocks) then we
    # ignore the read from the basic block perspective.

    # Handle access modifications at the statement level.
    if in(sym, tls.use)
        if write
            dprintln(3, "sym already in tls.use so adding to def")
            push!(tls.def, sym)
        end
    elseif read
        if in(sym, tls.def)
            throw(string("Found a read after a write at the statement level in liveness analysis."))
        end
        dprintln(3, "adding sym to tls.use")
        push!(tls.use, sym)
    else # must be a write
        dprintln(3, "adding sym to tls.def")
        push!(tls.def, sym)
    end

    # Handle access modifications at the basic block level.
    if in(sym, bb.use)
        if write
            dprintln(3, "sym already in bb.use so adding to def")
            push!(bb.def, sym)
        end
    elseif read
        if !in(sym, bb.def)
            dprintln(3, "adding sym to bb.use")
            push!(bb.use, sym)
        end
    else # must be a write
        dprintln(3, "adding sym to bb.def")
        push!(bb.def, sym)
    end

    nothing
end

@doc """
Holds the state during the AST traversal.
cfg = the control flow graph from the CFGs module.
map = our own map of CFG basic blocks to our own basic block information with liveness in it.
cur_bb = the current basic block in which we are processing AST nodes.
read = whether the sub-tree we are currently processing is being read or written.
ref_params = those arguments to the function that are passed by reference.
"""
type expr_state
    cfg :: CFGs.CFG
    map :: Dict{CFGs.BasicBlock, BasicBlock}
    cur_bb
    read
    ref_params :: Array{Symbol, 1}
    params_not_modified :: Dict{Tuple{Any,Array{DataType,1}}, Array{Int64,1}} # Store function/signature mapping to an array whose entries corresponding to whether that argument passed to that function can be modified.
    li :: Union{Void, LambdaInfo}

    function expr_state(cfg, no_mod)
        new(cfg, Dict{CFGs.BasicBlock, BasicBlock}(), nothing, true, Symbol[], no_mod, nothing)
    end
end

@doc """
The main return type from LivenessAnalysis.
Contains a dictionary that maps CFG basic block to liveness basic blocks.
Also contains the corresponding CFG.
"""
type BlockLiveness
    basic_blocks :: Dict{CFGs.BasicBlock, BasicBlock}
    cfg :: CFGs.CFG

    function BlockLiveness(bb, cfg)
      new(bb, cfg)
    end
end

@doc """
The live_in, live_out, def, and use routines are all effectively the same but just extract a different field name.
Here we extract this common behavior where x can be a liveness or CFG basic block or a liveness or CFG statement.
bl is BlockLiveness type as returned by a previous LivenessAnalysis.
field is the name of the field requested.
"""
function get_info_internal(x, bl :: BlockLiveness, field)
    if typeof(x) == BasicBlock
        return getfield(x, field)
    elseif typeof(x) == CFGs.BasicBlock
        bb = bl.basic_blocks[x]
        return getfield(bb, field)
    elseif typeof(x) == TopLevelStatement
        return getfield(x, field)
    elseif typeof(x) == CFGs.TopLevelStatement
        for i in bl.basic_blocks
          for j in i[2].statements
            if x == j.tls
              return getfield(j, field)
            end
          end
        end
        throw(string("Couldn't find liveness statement corresponding to cfg statement. "))
    else
      throw(string("get_info_internal called with non-BB and non-TopLevelStatement input."))
    end
end

@doc """
Get the live_in information for "x" where x can be a liveness or CFG basic block or a liveness or CFG statement.
"""
function live_in(x, bl :: BlockLiveness)
    get_info_internal(x, bl, :live_in)
end

@doc """
Get the live_out information for "x" where x can be a liveness or CFG basic block or a liveness or CFG statement.
"""
function live_out(x, bl :: BlockLiveness)
    get_info_internal(x, bl, :live_out)
end

@doc """
Get the def information for "x" where x can be a liveness or CFG basic block or a liveness or CFG statement.
"""
function def(x, bl :: BlockLiveness)
    get_info_internal(x, bl, :def)
end

@doc """
Get the use information for "x" where x can be a liveness or CFG basic block or a liveness or CFG statement.
"""
function use(x, bl :: BlockLiveness)
    get_info_internal(x, bl, :use)
end

@doc """
Overload of Base.show to pretty-print BlockLiveness type.
"""
function show(io::IO, bl::BlockLiveness)
    println(io)
    body_order = CFGs.getBbBodyOrder(bl.cfg)
    for i = 1:length(body_order)
      cfgbb = bl.cfg.basic_blocks[body_order[i]]
      if !haskey(bl.basic_blocks, cfgbb)
        println(io,"Could not find LivenessAnalysis basic block for CFG basic block = ", cfgbb)
      else
        bb = bl.basic_blocks[bl.cfg.basic_blocks[body_order[i]]]
        show(io, bb)
        println(io)
      end
    end
end

@doc """
Query if the symbol in argument "x" is defined in live_info which can be a BasicBlock or TopLevelStatement.
"""
function isDef(x :: SymGen, live_info)
  in(x, live_info.def)
end

@doc """
Search for a statement with the given top-level number in the liveness information.
Returns a LivenessAnalysis.TopLevelStatement having that top-level number or "nothing" if no such statement could be found.
"""
function find_top_number(top_number::Int, bl::BlockLiveness)
  # Liveness information stored in blocks so scan each block.
  for bb in bl.basic_blocks
    stmts = bb[2].statements
    # Scan each statement in this block for a matching statement number.
    for j = 1:length(stmts)
      if stmts[j].tls.index == top_number
        return stmts[j]
      end
    end
  end
  nothing
end


@doc """
Search for a basic block containing a statement with the given top-level number in the liveness information.
Returns a basic block label of a block having that top-level number or "nothing" if no such statement could be found.
"""
# Search for a statement with the given number in the liveness information.
function find_bb_for_statement(top_number::Int, bl::BlockLiveness)
  # Liveness information stored in blocks so scan each block.
  for bb in bl.basic_blocks
    stmts = bb[2].statements
    # Scan each statement in this block for a matching statement number.
    for j = 1:length(stmts)
      if stmts[j].tls.index == top_number
        return bb[1].label
      end
    end
  end

  dprintln(3,"Didn't find statement top_number in basic_blocks.")
  nothing
end

@doc """
Clear the live_in and live_out data corresponding to all basic blocks and statements and then recompute liveness information.
"""
function recompute_live_ranges(state, dfn)
    for bb in state.basic_blocks
        empty!(bb.live_in)
        empty!(bb.live_out)
        for s in bb.statements
          empty!(s.live_in)
          empty!(s.live_out)
        end
    end

    compute_live_ranges(state, dfn)

    nothing
end

@doc """
Compute the live_in and live_out information for each basic block and statement.
"""
function compute_live_ranges(state :: expr_state, dfn)
    found_change = true
    bbs = state.cfg.basic_blocks

    # Compute the inter-block live ranges first.
    while found_change
        # Iterate until quiescence.
        found_change = false

        # For each basic block in reverse depth-first order.
        for i = length(dfn):-1:1
            bb_index = dfn[i]
            bb = state.map[bbs[bb_index]]

            accum = Set{SymGen}()
            if bb_index == -2
              # Special case for final block.
              # Treat input arrays as live at end of function.
              accum = Set{SymGen}(state.ref_params)
              dprintln(3,"Final block live_out = ", accum)
            else
              # The live_out of this block is the union of the live_in of every successor block.
              for j in bb.cfgbb.succs
                accum = union(accum, state.map[j].live_in)
              end
            end

            bb.live_out = accum

            old_size = length(bb.live_in)

            # The live_in to this block is the union of things used in this block 
            # with the set of things used by successors and not defined in this block.
            # Note that for basic blocks, we do not create a "use" if the first "use"
            # is after a "def".
            bb.live_in = union(bb.use, setdiff(bb.live_out, bb.def))

            new_size = length(bb.live_in)
            if new_size != old_size
                found_change = true
            end
        end

    end

    # Compute the intra-block live ranges using the inter-block live ranges.
    # For each basic block.
    for i = 1:length(dfn)
        bb = state.map[bbs[dfn[i]]]

        tls = bb.statements

        # The lives at the end of the last statement of this block is the inter-block live_out.
        cur_live_out = bb.live_out

        # Go through the statements in reverse order.
        for j = length(tls):-1:1
            tls[j].live_out = cur_live_out;
            tls[j].live_in  = union(tls[j].use, setdiff(tls[j].live_out, tls[j].def))
            cur_live_out    = tls[j].live_in
        end
    end

    nothing
end

@doc """
Dump a bunch of debugging information about BlockLiveness.
"""
function dump_bb(bl :: BlockLiveness)
    if DEBUG_LVL >= 4
      f = open("bbs.dot","w")
      println(f, "digraph bbs {")
    end

    body_order = CFGs.getBbBodyOrder(bl.cfg)
    if DEBUG_LVL >= 3
      println("body_order = ", body_order)
    end

    for i = 1:length(body_order)
        bb = bl.basic_blocks[bl.cfg.basic_blocks[body_order[i]]]
        dprint(2,bb)

        if DEBUG_LVL >= 4
            for j in bb.cfgbb.succs
                println(f, bb.cfgbb.label, " -> ", j.label, ";")
            end
        end
    end

    if DEBUG_LVL >= 4
      println(f, "}")
      close(f)
    end
end

@doc """
Convert a compressed LambdaStaticData format into the uncompressed AST format.
"""
uncompressed_ast(l::LambdaStaticData) =
  isa(l.ast,Expr) ? l.ast : ccall(:jl_uncompress_ast, Any, (Any,Any), l, l.ast)

@doc """
Walk through a lambda expression.
We just need to extract the ref_params because liveness needs to keep those ref_params live at the end of the function.
We don't recurse into the body here because from_expr handles that with fromCFG.
"""
function from_lambda(ast :: Expr, depth :: Int64, state :: expr_state, callback :: Function, cbdata :: ANY)
  # :lambda expression
  state.li = CompilerTools.LambdaHandling.lambdaExprToLambdaInfo(ast)
  state.ref_params = CompilerTools.LambdaHandling.getRefParams(state.li)
  dprintln(3,"from_lambda: ref_params = ", state.ref_params)
end

@doc """
Walk through an array of expressions.
Just recursively call from_expr for each expression in the array.
"""
function from_exprs(ast :: Array{Any,1}, depth :: Int64, state :: expr_state, callback :: Function, cbdata :: ANY)
  # sequence of expressions
  # ast = [ expr, ... ]
  local len = length(ast)
  for i = 1:len
    dprintln(2,"Processing ast #",i," depth=",depth)
    dprintln(3,"ast[", i, "] = ", ast[i])
    from_expr(ast[i], depth, state, callback, cbdata)
  end
  nothing
end

@doc """
Walk through an assignment expression.
"""
function from_assignment(ast :: Array{Any,1}, depth :: Int64, state :: expr_state, callback :: Function, cbdata :: ANY)
  # :(=) assignment
  # ast = [ ... ]
  assert(length(ast) == 2)
  local lhs = ast[1]
  local rhs = ast[2]
  dprintln(3,"liveness from_assignment lhs = ", lhs, " rhs = ", rhs)
  # Process the right-hand side of the assignment unless it is a lambda.
  if isa(rhs, Expr) && rhs.head == :lambda
    # skip handling rhs lambdas
  else
    from_expr(rhs, depth, state, callback, cbdata)
  end
  dprintln(3,"liveness from_assignment handling lhs")
  # Handle the left-hand side of the assignment which is being written.
  state.read = false
  from_expr(lhs, depth, state, callback, cbdata)
  state.read = true
  dprintln(3,"liveness from_assignment done handling lhs")
end

@doc """
Add an entry the dictionary of which arguments can be modified by which functions.
"""
function addUnmodifiedParams(func, signature :: Array{DataType,1}, unmodifieds, state :: expr_state)
  state.params_not_modified[(func, signature)] = unmodifieds
end

@doc """
Get the type of some AST node.
"""
function typeOfOpr(x :: ANY, li :: LambdaInfo)
  dprintln(3,"starting typeOfOpr, type = ", typeof(x))
  if isa(x, Expr) ret = x.typ
  elseif isa(x, Symbol)
    ret = getType(x, li)
  elseif isa(x, SymbolNode)
    typ1 = getType(x.name, li)
    if x.typ != typ1
      dprintln(2, "typeOfOpr x.typ and lambda type different")
      dprintln(2, "x.name = ", x.name, " x.typ = ", x.typ, " typ1 = ", typ1)
      dprintln(2, "li = ", li)
    end
    assert(x.typ <: typ1)
    assert(isa(x.typ, Type))
     ret = x.typ
  elseif isa(x, GenSym) ret = getType(x, li)
  elseif isa(x, GlobalRef) ret = typeof(eval(x))
  elseif isa(x, SimpleVector)
    svec_types = [ typeOfOpr(x[i], li) for i = 1:length(x) ]
    ret = Tuple{svec_types...}
  else ret = typeof(x)
  end

  if typeof(ret) != DataType
    dprintln(3,"Final typeof(ret) != DataType, instead = ", typeof(ret))
    if typeof(ret) == Union
      ret = Tuple{ret.types...} 
    else
      dprintln(2, "typeof(ret) != DataType")
      throw(string("typeOfOpr found SymbolNode type that was not a DataType or a Union of DataTypes."))
    end
  end

  return ret
end

@doc """
Returns true if a parameter is passed by reference.
isbits types are not passed by ref but everything else is (is this always true..any exceptions?)
"""
function isPassedByRef(x, state :: expr_state)
  if isa(x, Tuple)
    return true
  elseif isbits(x)
    return false
  else
    return true
  end 
end

function showNoModDict(dict)
  for i in dict
    try
    dprintln(4, "(", i[1][1], ",", i[1][2], ") => ", i[2])
    catch
    targs = i[1][2]
    assert(isa(targs, Tuple))
    println("EXCEPTION: type = ", typeof(targs))
    for j = 1:length(targs)
       println(j, " = ", typeof(targs[j]))
       println(targs[j])
    end
    end
  end
end

# If true, will assume that functions without "!" don't update their arguments.
use_inplace_naming_convention = false
function set_use_inplace_naming_convention()
  global use_inplace_naming_convention = true
end

wellknown_all_unmodified = Set{Any}()

function __init__()
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:(./)), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:(.*)), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:(.+)), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:(.-)), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:(/)),  force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:(*)),  force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:(+)),  force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:(-)),  force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:(<=)),  force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:(<)),  force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:(>=)),  force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:(>)),  force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:size), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:maximum), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:minimum), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:max), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:min), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:mean), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:ctranspose), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base.LinAlg,:norm), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:Ac_mul_B), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:Ac_mul_Bc), force = true))
  push!(wellknown_all_unmodified, Base.resolve(GlobalRef(Base,:box), force = true))
#  push!(wellknown_all_unmodified, eval(TopNode(:(!))))
end

@doc """
For a given function and signature, return which parameters can be modified by the function.
If we have cached this information previously then return that, else cache the information for some
well-known functions or default to presuming that all arguments could be modified.
"""
function getUnmodifiedArgs(func :: ANY, args, arg_type_tuple :: Array{DataType,1}, state :: expr_state)
  dprintln(3,"getUnmodifiedArgs func = ", func, " type = ", typeof(func))
  dprintln(3,"getUnmodifiedArgs args = ", args)
  dprintln(3,"getUnmodifiedArgs arg_type_tuple = ", arg_type_tuple)
  dprintln(3,"getUnmodifiedArgs len(args) = ", length(arg_type_tuple))
  showNoModDict(state.params_not_modified)

  default_result = Int64[(isPassedByRef(x, state) ? 0 : 1) for x in arg_type_tuple]
  if length(default_result) == 0
    return default_result
  end

  if typeof(func) == GlobalRef
    func = Base.resolve(func, force=true)
    dprintln(3,"getUnmodifiedArgs func = ", func, " type = ", typeof(func))
  elseif typeof(func) == TopNode
    func = eval(func)
    dprintln(3,"getUnmodifiedArgs func = ", func, " type = ", typeof(func))
  elseif typeof(func) == Expr
    return default_result
  end

  # We are seeing Symbol's getting here as well due to incomplete name resolution.  Once this is 
  # fixed then maybe we re-enable this assertion as a sanity check.
#  assert(typeof(func) == Function || typeof(func) == IntrinsicFunction)

  fs = (func, arg_type_tuple)
  if haskey(state.params_not_modified, fs)
    res = state.params_not_modified[fs]
    assert(length(res) == length(args))
    dprintln(3,"function already in params_not_modified so returning previously computed value")
    return res
  end 

  for i in state.params_not_modified
    (f1, t1) = i[1]
    dprintln(3,"f1 = ", f1, " t1 = ", t1, " f1type = ", typeof(f1), " len(t1) = ", length(t1))
    if func == f1 
      dprintln(3,"function matches")
      if Tuple{arg_type_tuple...} <: Tuple{t1...}
        res = i[2]
        assert(length(res) == length(args))
        addUnmodifiedParams(func, arg_type_tuple, res, state)
        dprintln(3,"exact match not found but sub-type match found")
        return res
      end
    end
  end

  if in(func, wellknown_all_unmodified)
    dprintln(3,"Well-known function known not to modify args.")
    addUnmodifiedParams(func, arg_type_tuple, ones(Int64, length(args)), state) 
  else
    if func == eval(TopNode(:tuple))
      dprintln(3,"Detected tuple in getUnmodifiedArgs so returning that no arguments are modified.")
      addUnmodifiedParams(func, arg_type_tuple, [1 for x in arg_type_tuple], state)
      return state.params_not_modified[fs]
    end

    dprintln(3,"is func generic => ", isgeneric(func))
    if use_inplace_naming_convention && isgeneric(func) && !in('!', string(Base.function_name(func)))
      dprintln(3,"using naming convention that function has no ! so it doesn't modify anything in place.")
      addUnmodifiedParams(func, arg_type_tuple, [1 for x in arg_type_tuple], state)
    else
      dprintln(3,"fallback to args passed by ref as modified.")
      addUnmodifiedParams(func, arg_type_tuple, default_result, state)
    end
  end

  return state.params_not_modified[fs]
end

@doc """
Walk through a call expression.
"""
function from_call(ast :: Array{Any,1}, depth :: Int64, state :: expr_state, callback :: Function, cbdata :: ANY)
  assert(length(ast) >= 1)
  local fun  = ast[1]
  local args = ast[2:end]
  dprintln(2,"from_call fun = ", fun, " typeof fun = ", typeof(fun))
   
  # Form the signature of the call in a tuple.
  arg_type_array = DataType[]
  for i = 1:length(args)
    dprintln(3, "arg ", i, " = ", args[i], " typeof arg = ", typeof(args[i]))
    too = typeOfOpr(args[i], state.li)
    if !isa(too, DataType)
      dprintln(0, "arg type = ", too, " tootype = ", typeof(too))
    end
    push!(arg_type_array, typeOfOpr(args[i], state.li)) 
  end
  dprintln(3, "arg_type_array = ", arg_type_array)
  #arg_type_tuple = Tuple{arg_type_array...}
  # See which arguments to the function can be modified by the function.
  unmodified_args = getUnmodifiedArgs(fun, args, arg_type_array, state)
  assert(length(unmodified_args) == length(args))
  dprintln(3,"unmodified_args = ", unmodified_args)
  
  # symbols don't need to be translated
  if typeof(fun) != Symbol
      from_expr(fun, depth, state, callback, cbdata)
  end

  # For each argument.
  for i = 1:length(args)
    argtyp = typeOfOpr(args[i], state.li)
    dprintln(2,"cur arg = ", args[i], " type = ", argtyp)

    # We can always potentially read first.
    from_expr(args[i], depth+1, state, callback, cbdata)
    if unmodified_args[i] == 0
      # The argument could be modified so treat it as a "def".
      state.read = false
      from_expr(args[i], depth+1, state, callback, cbdata)
      state.read = true
    end
  end
end

@doc """
The default callback that processes no non-standard Julia AST nodes.
"""
function not_handled(a,b)
  nothing
end

@doc """
Count the number of times that the symbol in "s" is defined in all the basic blocks.
"""
function countSymbolDefs(s, lives)
  dprintln(3,"countSymbolDefs: ", s)
  count = 0
  for (j,bb) in lives.basic_blocks
    dprintln(3,"Examining block ", j.label)
    for stmt in bb.statements
      if in(s, stmt.def) 
          dprintln(3, "Found symbol defined in block ", j.label, " in statement: ", stmt)
          count += 1 
      end
    end
  end
  return count
end

@doc """
ENTRY point to liveness analysis.
You must pass a :lambda Expr as "ast".
If you have non-standard AST nodes, you may pass a callback that will be given a chance to process the non-standard node first.
"""
function from_expr(ast :: Expr, callback=not_handled, cbdata :: ANY = nothing, no_mod=Dict{Tuple{Any,Array{DataType,1}}, Array{Int64,1}}())
  #dprintln(3,"liveness from_expr no_mod = ", no_mod)
  assert(ast.head == :lambda)
  cfg = CFGs.from_ast(ast)      # Create the CFG from this lambda Expr.
  live_res = expr_state(cfg, no_mod)
  # Just to process the lambda and extract what the ref_params are.
  from_expr(ast, 1, live_res, callback, cbdata)
  # Process the body of the function via the CFG.
  fromCFG(live_res, cfg, callback, cbdata)
end

@doc """
This function gives you the option of calling the ENTRY point from_expr with an ast and several optional named arguments.
"""
function from_expr(ast :: Expr; callback=not_handled, cbdata :: ANY = nothing, no_mod=Dict{Tuple{Any,Array{DataType,1}}, Array{Int64,1}}())
  from_expr(ast, callback, cbdata, no_mod)
end

@doc """
Extract liveness information from the CFG.
"""
function fromCFG(live_res, cfg :: CFGs.CFG, callback :: Function, cbdata :: ANY)
  dprintln(2,"fromCFG")
  CFGs.dump_bb(cfg)   # Dump debugging information if set_debug_level is high enough.

  # For each basic block.
  for bb in cfg.basic_blocks
    live_res.map[bb[2]] = BasicBlock(bb[2])
    live_res.cur_bb = live_res.map[bb[2]]

    # For each statement in each block.
    for i = 1:length(bb[2].statements)
       cur_stmt = bb[2].statements[i]
       # Add this statement to our list of statements in the current LivenessAnalysis.BasicBlock.
       push!(live_res.cur_bb.statements, TopLevelStatement(cur_stmt)) 
       dprintln(3,"fromCFG stmt = ", cur_stmt.expr)
       # Process the statement looking for def and use.
       from_expr(cur_stmt.expr, 1, live_res, callback, cbdata)
    end
  end

  # Compute live_in and live_out for basic blocks and statements.
  compute_live_ranges(live_res, cfg.depth_first_numbering)
  dprintln(2,"Dumping basic block info from_expr.")
  ret = BlockLiveness(live_res.map, cfg)
  dump_bb(ret)
  return ret
end

@doc """
Process a return Expr node which is just a recursive processing of all of its args.
"""
function from_return(args, depth :: Int64, state :: expr_state, callback :: Function, cbdata :: ANY)
    dprintln(2,"Expr return: ")
    from_exprs(args, depth, state, callback, cbdata)
    nothing
end

@doc """
Process a gotoifnot which is just a recursive processing of its first arg which is the conditional.
"""
function from_if(args, depth :: Int64, state :: expr_state, callback :: Function, cbdata :: ANY)
    # The structure of the if node is an array of length 2.
    assert(length(args) == 2)
    # The first index is the conditional.
    if_clause  = args[1]

    # Process the conditional as part of the current basic block.
    from_expr(if_clause, depth, state, callback, cbdata)
    nothing
end

@doc """
Generic routine for how to walk most AST node types.
"""
function from_expr(ast :: ANY, depth :: Int64, state :: expr_state, callback :: Function, cbdata :: ANY)
  if typeof(ast) == LambdaStaticData
      # ast = uncompressed_ast(ast)
      # skip processing LambdaStaticData
      return nothing
  end
  local asttyp = typeof(ast)
  dprintln(2,"from_expr depth=",depth," ", " asttyp = ", asttyp)

  handled = callback(ast, cbdata)
  if handled != nothing
#    addStatement(top_level, state, ast)
    if length(handled) > 0
      dprintln(3,"Processing expression from callback for ", ast)
      dprintln(3,handled)
      from_exprs(handled, depth+1, state, callback, cbdata)
      dprintln(3,"Done processing expression from callback.")
    end
    return nothing
  end

  if isa(ast, Tuple)
    for i = 1:length(ast)
        from_expr(ast[i], depth, state, callback, cbdata)
    end
  elseif asttyp == Expr
    #addStatement(top_level, state, ast)

    dprint(2,"Expr ")
    local head = ast.head
    local args = ast.args
    local typ  = ast.typ
    dprintln(2,head, " ", args)
    if head == :lambda
        from_lambda(ast, depth, state, callback, cbdata)
    elseif head == :body
        dprintln(0,":body found in from_expr")
        throw(string(":body found in from_expr"))
    elseif head == :(=)
        from_assignment(args,depth,state, callback, cbdata)
    elseif head == :return
        from_return(args,depth,state, callback, cbdata)
    elseif head == :call
        from_call(args,depth,state, callback, cbdata)
        # TODO: catch domain IR result here
    elseif head == :call1
        from_call(args,depth,state, callback, cbdata)
        # TODO?: tuple
    elseif head == :line
        # skip
    elseif head == :arraysize
        from_exprs(args, depth+1, state, callback, cbdata)
        # skip
    elseif head == :alloc
        from_exprs(args[2], depth+1, state, callback, cbdata)
        # skip
    elseif head == :copy
        from_exprs(args, depth+1, state, callback, cbdata)
        # skip
    elseif head == :assert || head == :select || head == :ranges || head == :range || head == :tomask
        from_exprs(args, depth+1, state, callback, cbdata)
    elseif head == :copyast
        dprintln(2,"copyast type")
        # skip
    elseif head == :gotoifnot
        from_if(args,depth,state, callback, cbdata)
    elseif head == :new
        from_exprs(args, depth+1, state, callback, cbdata)
    elseif head == :tuple
        from_exprs(args, depth+1, state, callback, cbdata)
    elseif head == :getindex
        from_exprs(args, depth+1, state, callback, cbdata)
    elseif head == :boundscheck
    elseif head == :(.)
        # skip handling fields of a type
        # ISSUE: will this cause precision issue, or correctness issue? I guess it is precision?
    elseif head == :quote
        from_exprs(args, depth+1, state, callback, cbdata)
    elseif head == symbol("'")
        from_exprs(args, depth+1, state, callback, cbdata)
    elseif head == :meta
        # Intentionally do nothing.
    elseif head == :type_goto
        # Intentionally do nothing.
    else
        throw(string("from_expr: unknown Expr head :", head))
    end
  elseif asttyp == LabelNode
    assert(false)
#    from_label(ast.label, state, callback, cbdata)
  elseif asttyp == GotoNode
#    INTENTIONALLY DO NOTHING
  elseif asttyp == Symbol
    #addStatement(top_level, state, ast)
    dprintln(2,"Symbol type ", ast)
    add_access(state.cur_bb, ast, state.read)
  elseif asttyp == LineNumberNode
    #skip
  elseif asttyp == SymbolNode # name, typ
    #addStatement(top_level, state, ast)
    dprintln(2,"SymbolNode type ", ast.name, " ", ast.typ)
    add_access(state.cur_bb, ast.name, state.read)
  elseif asttyp == GenSym
    dprintln(2,"GenSym type ", ast)
    add_access(state.cur_bb, ast, state.read)
  elseif asttyp == TopNode    # name
    #skip
  elseif isdefined(:GetfieldNode) && asttyp == GetfieldNode  # GetfieldNode = value + name
    #addStatement(top_level, state, ast)
    dprintln(3,"GetfieldNode type ",typeof(ast.value), " ", ast)
  elseif isdefined(:GlobalRef) && asttyp == GlobalRef
    #addStatement(top_level, state, ast)
    dprintln(3,"GlobalRef type ",typeof(ast.mod), " ", ast)  # GlobalRef = mod + name
  elseif asttyp == QuoteNode
    #addStatement(top_level, state, ast)
    local value = ast.value
    #TODO: fields: value
    dprintln(3,"QuoteNode type ",typeof(value))
  # elseif asttyp == Int64 || asttyp == Int32 || asttyp == Float64 || asttyp == Float32
  elseif isbits(asttyp)
    #addStatement(top_level, state, ast)
    #skip
  elseif asttyp.name == Array.name
    #addStatement(top_level, state, ast)
    dprintln(3,"Handling case of AST node that is an array. ast = ", ast, " typeof(ast) = ", asttyp)
    for i = 1:length(ast)
      from_expr(ast[i], depth, state, callback, cbdata)
    end
  elseif asttyp == DataType
    #addStatement(top_level, state, ast)
  elseif asttyp == ()
    #addStatement(top_level, state, ast)
  elseif asttyp == ASCIIString || asttyp == UTF8String
    #addStatement(top_level, state, ast)
  elseif asttyp == NewvarNode
    #addStatement(top_level, state, ast)
  elseif asttyp == Void 
    #addStatement(top_level, state, ast)
  elseif asttyp == AccessSummary
    dprintln(3, "Incorporating AccessSummary")
    for i in ast.use
      add_access(state.cur_bb, i, true)
    end
    for i in ast.def
      add_access(state.cur_bb, i, false)
    end  
  elseif asttyp == Module
    #skip
  else
    throw(string("from_expr: unknown AST type :", asttyp, " ", ast))
  end
  nothing
end

end

