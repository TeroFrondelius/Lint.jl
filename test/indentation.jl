using Base.Test
using Lint

@testset "indentation and line length tests" begin
test_str = """
using somemodule

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
        else
            c = 4*b
        end
    end
end
"""

@test isempty(lintstr(test_str))

msgs = lintstr("\n    a=1\n")
@test msgs[1].code == :I772
@test msgs[1].line == 2
@test msgs[1].message == "expected indentation 0 is 4"

comment = "very long comment"
msgs = lintstr("b = 2 #"*repeat(comment,5))
@test msgs[1].code == :I773
@test msgs[1].line == 1
@test msgs[1].message == "line length exceeds 80 characters"
end
