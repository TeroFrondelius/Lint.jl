test_str = """
include somemodule

\"\"\"
if
if
if
\"\"\"
function a(b)
    for i in 1:10
        if i == 1
            println("start")
        elseif i == 10
            println("end")
        end
    end
end
"""


increaseIndentPattern = ["if","while","for","function","macro","immutable",
                         "type","let","quote","try","begin","do","else",
                         "elseif","catch","finally"]
decreaseIndentPattern = ["end","else","elseif","catch","finally"]

using Tokenize
using Lint

function countwhitespaces(inpstr)
    tok = tokenize(inpstr)
    state = start(tok)
    indentation = Dict()
    while !done(tok, state)
        (i, state) = next(tok, state)
        if string(i.kind) == "WHITESPACE" && (i.endpos[1] > i.startpos[1])
            indentation[i.endpos[1]] = i.endpos[2]
        end
    end
    indentation
end

function countidentations(inpstr)
    tok = tokenize(inpstr)
    state = start(tok)
    indentation = 0
    output = Dict()
    nextline = false
    while !done(tok, state)
        (i, state) = next(tok, state)
        line = i.endpos[1]
        if nextline
            indentation += 4
            nextline = false
        end
        if lowercase(string(i.kind)) in increaseIndentPattern
            nextline = true
        end
        if lowercase(string(i.kind)) in decreaseIndentPattern
            indentation -= 4
            output[line] = indentation
        end
        if string(i.kind) == "WHITESPACE" && (i.endpos[1] > i.startpos[1])
            output[line] = indentation
        end
    end
    output
end

function lintidentation(ctx::LintContext, lint_str)
    whitespaces = countwhitespaces(lint_str)
    indentations = countidentations(lint_str)
    lines = keys(whitespaces)
    output = []
    for line in lines
        actual = whitespaces[line]
        expected = indentations[line]
        if actual != expected
            text = "expected indentation $expected is $actual"
            push!(output, msg(ctx, :I772, text))
        end
    end
    output
end

whitespaces = countwhitespaces(test_str)
indentations = countidentations(test_str)
for (i,line) in enumerate(split(test_str,"\n"))
    if haskey(whitespaces,i)
        ws = whitespaces[i]
    else
        ws = " "
    end
    if haskey(indentations,i)
        inden = indentations[i]
    else
        inden = " "
    end
    println("$ws $inden $line")
end



#=
tok = tokenize(test_str)

state = start(tok)
indent = 0
line = 0
indentation = []
while !done(tok, state)
    (i, state) = next(tok, state)
    if lowercase(string(i.kind)) in decreaseIndentPattern
        indent -= 4
    end

    if i.startpos[1] >=  line
        line = i.endpos[1]
        for j in 1:(i.endpos[1]-i.startpos[1])
            push!(indentation,line)
        end
    end

    if lowercase(string(i.kind)) in increaseIndentPattern
        indent += 4
    end
    #print(i)
end


for i in collect(tok)
    if string(i.kind) == "WHITESPACE"
        dump(i)
    end
end
=#



# https://github.com/JuliaEditorSupport/atom-language-julia/blob/master/settings/language-julia.cson

#=

indent = 1
for line in split(test_str,"\n")
    if ismatch(decreaseIndentPattern,line)
        indent += -4
    end
    whitespaces = Int(length(match(r"^\s*",line).match)) + 1
    println("$indent $whitespaces $line")
    if ismatch(increaseIndentPattern,line)
        indent += 4
    end
end
=#
