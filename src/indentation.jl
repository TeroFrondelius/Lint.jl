
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
    for line in lines
        actual = whitespaces[line]
        expected = indentations[line]
        if actual != expected
            text = "expected indentation $expected is $actual"
            ctx.line = line - 1
            msg(ctx, :I772, text)
        end
    end
end

function lintlinelenght(ctx::LintContext, lint_str)
    lines = split(lint_str,"\n")
    for (i,line) in enumerate(lines)
        if length(line) > 80
            text = "line length exceeds 80 characters"
            ctx.line = i - 1
            msg(ctx, :I773, text)
        end
    end
end
