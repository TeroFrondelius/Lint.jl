__precompile__(true)

module Lint

using Base.Meta
using Compat
using Compat.TypeUtils
using JSON
import Compat: readline

if isdefined(Base, :unwrap_unionall)
    using Base: unwrap_unionall
else
    unwrap_unionall(x) = x
end

export LintMessage, LintContext, LintStack
export lintfile, lintstr, lintpkg, lintserver, @lintpragma
export iserror, iswarning, isinfo
export test_similarity_string

const SIMILARITY_THRESHOLD = 10.0
const ASSIGN_OPS = [:(=), :(+=), :(-=), :(*=), :(/=), :(&=), :(|=)]
const COMPARISON_OPS = [:(==), :(<), :(>), :(<=), :(>=), :(!=) ]

# no-op. We have to use macro inside type declaration as it disallows actual function calls
macro lintpragma(s)
end

import Base: ==

include("exprutils.jl")
using .ExpressionUtils

include("statictype.jl")

include("linttypes.jl")
include("messages.jl")
include("guesstype.jl")
include("variables.jl")
include("pragma.jl")
include("functions.jl")
include("types.jl")
include("modules.jl")
include("blocks.jl")
include("controls.jl")
include("macros.jl")
include("knowndeprec.jl")
include("dict.jl")
include("ref.jl")
include("curly.jl")
include("misc.jl")
include("init.jl")
include("result.jl")
include("dynamic.jl")

function lintpkg(pkg::AbstractString)
    p = joinpath(Pkg.dir(pkg), "src", basename(pkg) * ".jl")
    if !ispath(p)
        throw("cannot find path: " * p)
    end
    LintResult(lintpkgforfile(p))
end


"""
Lint the package for a file.
If file is in src, lint Package.jl and its includes.
If file is in test, lint runtests.jl and its includes.
If file is in base lint all files in base dir.
"""
function lintpkgforfile(path::AbstractString, ctx::LintContext=LintContext())
    path = abspath(path)
    if ispath(ctx.path)
        if is_windows()
            len = count(x -> x == '\\', path)
        else
            len = count(x -> x == '/', path) - 1
        end
        for i = 1:len
            path, folder = splitdir(path)
            if folder == "src"
                file = joinpath(path, folder, basename(path) * ".jl")
                if ispath(file)
                    lintinclude(ctx, file)
                end
                break
            elseif folder == "test"
                file = joinpath(path, folder, "runtests.jl")
                if ispath(file)
                    lintinclude(ctx, file)
                end
                break
            elseif folder == "base"
                lintdir(joinpath(path, folder), ctx)
                break
            end
        end
    end
    ctx.messages
end

function lintfile(file::AbstractString)
    if !ispath(file)
        throw("no such file exists")
    end
    str = open(readstring, file)
    lintfile(file, str)
end

function lintfile(file::AbstractString, code::AbstractString)
    ctx = LintContext(file)

    msgs = lintstr(code, ctx)

    # If we have an undeclared symbol, lint the package to try and resolve
    for message in msgs
        if message.code == :E321 # undeclared symbol
            message = lintpkgforfile(ctx.file, ctx)
            break
        end
    end

    filter!(msg -> msg.file == file, msgs)
    clean_messages!(msgs)

    LintResult(msgs)
end

function lintstr(str::AbstractString, ctx::LintContext = LintContext(), lineoffset = 0)
    linecharc = cumsum(map(x->endof(x)+1, split(str, "\n", keep=true)))
    numlines = length(linecharc)
    i = start(str)
    while !done(str,i)
        problem = false
        ex = nothing
        linerange = searchsorted(linecharc, i)
        if linerange.start > numlines # why is it not donw?
            break
        else
            linebreakloc = linecharc[linerange.start]
        end
        if linebreakloc == i || isempty(strip(str[i:(linebreakloc-1)]))# empty line
            i = linebreakloc + 1
            continue
        end
        ctx.lineabs = linerange.start + lineoffset
        try
            (ex, i) = parse(str,i)
        catch y
            if typeof(y) != ParseError || y.msg != "end of input"
                msg(ctx, :E111, string(y))
            end
            problem = true
        end
        if !problem
            ctx.line = 0
            lintexpr(ex, ctx)
        else
            break
        end
    end
    ctx.messages
end

function lintexpr(ex::Symbol, ctx::LintContext)
    registersymboluse(ex, ctx)
end

function lintexpr(ex::QuoteNode, ctx::LintContext)
    if typeof(ex.value) == Expr
        ctx.quoteLvl += 1
        lintexpr(ex.value, ctx)
        ctx.quoteLvl -= 1
    end
end

function lintexpr(ex::Expr, ctx::LintContext)
    for h in values(ctx.callstack[end].linthelpers)
        if h(ex, ctx) == true
            return
        end
    end

    if ex.head == :line
        # ignore line numer nodes
        return
    elseif ex.head == :block
        lintblock(ex, ctx)
    elseif ex.head == :quote
        ctx.quoteLvl += 1
        lintexpr(ex.args[1], ctx)
        ctx.quoteLvl -= 1
    elseif ex.head == :if
        lintifexpr(ex, ctx)
    elseif ex.head == :(=) && typeof(ex.args[1])==Expr && ex.args[1].head == :call
        lintfunction(ex, ctx)
    elseif in(ex.head, ASSIGN_OPS)
        lintassignment(ex, ex.head, ctx)
    elseif ex.head == :local
        lintlocal(ex, ctx)
    elseif ex.head == :global
        lintglobal(ex, ctx)
    elseif ex.head == :const
        if typeof(ex.args[1]) == Expr && ex.args[1].head == :(=)
            lintassignment(ex.args[1], :(=), ctx; isConst = true)
        end
    elseif ex.head == :module
        lintmodule(ex, ctx)
    elseif ex.head == :using
        lintusing(ex, ctx)
    elseif ex.head == :export
        lintexport(ex, ctx)
    elseif ex.head == :import # single name import. e.g. import Base
        lintimport(ex, ctx)
    elseif ex.head == :importall
        lintimport(ex, ctx; all=true)
    elseif ex.head == :comparison # only the odd indices
        for i in 1:2:length(ex.args)
            # comparison like match != 0:-1 is allowed, and shouldn't trigger lint warnings
            if Meta.isexpr(ex.args[i], :(:)) && length(ex.args[i].args) == 2 &&
                typeof(ex.args[i].args[1]) <: Real &&
                typeof(ex.args[i].args[2]) <: Real
                continue
            else
                lintexpr(ex.args[i], ctx)
            end
        end
        lintcomparison(ex, ctx)
    elseif ex.head == :type
        linttype(ex, ctx)
    elseif ex.head == :typealias
        # TODO: deal with X{T} = Y assignments, also const X = Y
        linttypealias(ex, ctx)
    elseif ex.head == :abstract
        lintabstract(ex, ctx)
    elseif ex.head == :bitstype
        lintbitstype(ex, ctx)
    elseif ex.head == :(->)
        lintlambda(ex, ctx)
    elseif ex.head == :($) && ctx.quoteLvl > 0 # an unquoted node inside a quote node
        ctx.quoteLvl -= 1
        lintexpr(ex.args[1], ctx)
        ctx.quoteLvl += 1
    elseif ex.head == :function
        lintfunction(ex, ctx)
    elseif ex.head == :stagedfunction
        lintfunction(ex, ctx, isstaged=true)
    elseif ex.head == :macrocall && ex.args[1] == Symbol("@generated")
        lintfunction(ex.args[2], ctx, isstaged=true)
    elseif ex.head == :macro
        lintmacro(ex, ctx)
    elseif ex.head == :macrocall
        lintmacrocall(ex, ctx)
    elseif ex.head == :call
        lintfunctioncall(ex, ctx)
    elseif ex.head == :(:)
        lintrange(ex, ctx)
    elseif ex.head == :(::) # type assert/convert
        lintexpr(ex.args[1], ctx)
    elseif ex.head == :(.) # a.b
        lintexpr(ex.args[1], ctx)
    elseif ex.head == :ref # it could be a ref a[b], or an array Int[1,2]
        lintref(ex, ctx)
    elseif ex.head == :typed_vcat# it could be a ref a[b], or an array Int[1,2]
        linttyped_vcat(ex, ctx)
    elseif ex.head == :vcat
        lintvcat(ex, ctx)
    elseif ex.head == :vect # 0.4
        lintvect(ex, ctx)
    elseif ex.head == :hcat
        linthcat(ex, ctx)
    elseif ex.head == :typed_hcat
        linttyped_hcat(ex, ctx)
    elseif ex.head == :cell1d
        lintcell1d(ex, ctx)
    elseif ex.head == :while
        lintwhile(ex, ctx)
    elseif ex.head == :for
        lintfor(ex, ctx)
    elseif ex.head == :let
        lintlet(ex, ctx)
    elseif ex.head in (:comprehension, :dict_comprehension, :generator)
        lintcomprehension(ex, ctx; typed = false)
    elseif ex.head in (:typed_comprehension, :typed_dict_comprehension)
        lintcomprehension(ex, ctx; typed = true)
    elseif ex.head == :try
        linttry(ex, ctx)
    elseif ex.head == :curly # e.g. Ptr{T}
        lintcurly(ex, ctx)
    elseif ex.head in [:(&&), :(||)]
        lintboolean(ex.args[1], ctx)
        lintexpr(ex.args[2], ctx) # do not enforce boolean. e.g. b==1 || error("b must be 1!")
    elseif ex.head == :incomplete
        msg(ctx, :E112, ex.args[1])
    else
        for sube in ex.args
            lintexpr(sube, ctx)
        end
    end
end

# no-op fallback for other kinds of expressions (e.g. LineNumberNode) that we
# don’t care to handle
lintexpr(::Any, ::LintContext) = return

"""
Include a file to your lintContext.
Does nothing if file does not exist or has already been included.
"""
function lintinclude(ctx::LintContext, file::AbstractString)
    if ispath(file) && !(file in ctx.included) && file != ctx.file
        if !(ctx.file in ctx.included) # We don't want to lint the file again
            push!(ctx.included, ctx.file)
        end
        #println("including: $file")
        push!(ctx.included, file)

        oldpath = ctx.path
        oldfile = ctx.file
        oldlineabs = ctx.lineabs

        str = open(readstring, file)
        ctx.file = file
        ctx.path = dirname(file)
        ctx.lineabs = 1
        lintstr(str, ctx)

        ctx.file = oldfile
        ctx.path = oldpath
        ctx.lineabs = oldlineabs
    end
end

"""
Lint all .jl ending files at a given directory.
Will ignore LintContext file and already included files.
"""
function lintdir(dir::AbstractString, ctx::LintContext=LintContext())
    for file in readdir(dir)
        if endswith(file, ".jl")
            file = joinpath(dir, file)
            if !isdir(file)
                lintinclude(ctx, file)
            end
        end
    end
    ctx.messages
end

function convertmsgtojson(msgs, style, dict_data)
    if style == "lint-message"
        return msgs
    end
    output = Any[]
    for msg in msgs
        evar = msg.variable
        txt = msg.message
        file = msg.file
        linenumber = msg.line
        # Atom index starts from zero thus minus one
        errorrange = Array[[linenumber-1, 0], [linenumber-1, 80]]
        code = string(msg.code)
        if code[1] == 'I'
            etype = "info"
            etypenumber = 3
        elseif code[1] == 'W'
            etype = "warning"
            etypenumber = 2
        else
            etype = "error"
            etypenumber = 1
        end

        if style == "standard-linter-v1"
            if haskey(dict_data,"show_code")
                if dict_data["show_code"]
                    msgtext = "$code $evar: $txt"
                else
                    msgtext = "$evar: $txt"
                end
            else
                msgtext = "$code $evar: $txt"
            end
            push!(output, Dict("type" => etype,
                               "text" => msgtext,
                               "range" => errorrange,
                               "filePath" => file))
        elseif style == "vscode"
            push!(output, Dict("severity" => etypenumber,
                               "message" => "$evar: $txt",
                               "range" => errorrange,
                               "filePath" => file,
                               "code" => code,
                               "source" => "Lint.jl"))
        elseif style == "standard-linter-v2"
            push!(output, Dict("severity" => etype,
                               "location" => Dict("file" => file,
                                                   "position" => errorrange),
                               "excerpt" => code,
                               "description" => "$evar: $txt"))

        end
    end
    return output
end


function filtermsgs(msgs,dict_data)
    if haskey(dict_data,"ignore_warnings")
        if dict_data["ignore_warnings"]
            msgs = filter(i -> !iswarning(i), msgs)
        end
    end
    if haskey(dict_data,"ignore_info")
        if dict_data["ignore_info"]
            msgs = filter(i -> !isinfo(i), msgs)
        end
    end
    if haskey(dict_data,"ignore_codes")
        msgs = filter(i -> !(string(i.code) in dict_data["ignore_codes"]), msgs)
    end
    return msgs
end


function readandwritethestream(conn,style)
    if style == "original_behaviour"
        # println("Connection accepted")
        # Get file, code length and code
        file = readline(conn)
        # println("file: ", file)
        code_len = parse(Int, readline(conn))
        # println("Code bytes: ", code_len)
        code = Compat.UTF8String(read(conn, code_len))
        # println("Code received")
        # Do the linting
        msgs = lintfile(file, code)
        # Write response to socket
        for i in msgs
            write(conn, string(i))
            write(conn, "\n")
        end
        # Blank line to indicate end of messages
        write(conn, "\n")
    else
        dict_data = JSON.parse(conn)
        msgs = lintfile(dict_data["file"], dict_data["code_str"])
        msgs = filtermsgs(msgs, dict_data)
        out = convertmsgtojson(msgs, style, dict_data)
        JSON.print(conn, out)
    end
end

function lintserver(port,style="original_behaviour")
    server = listen(port)
    try
        println("Server running on port/pipe $port ...")
        while true
            conn = accept(server)
            @async try
                readandwritethestream(conn,style)
            catch err
                println(STDERR, "connection ended with error $err")
            finally
                close(conn)
                # println("Connection closed")
            end
        end
    finally
        close(server)
        println("Server closed")
    end
end


# precompile hints
include("precompile.jl")

end
