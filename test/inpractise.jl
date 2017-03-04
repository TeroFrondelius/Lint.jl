using Lint
using Base.Test

# TODO: E332, E412, E417, E418

errordic = Dict(:E311=>"include(\"not_existing.jl\")",
                :E321=>"something",
                :E331=>"function test(a,a)\n end",
                :E333=>"export a,a",
                :E334=>"Dict(\"a\"=>1,\"a\"=>2)",
                :E411=>"function test(a=1,b)\nend",
                :E413=>"bar(a,b,x...,c) = (a,b,x)",
                :E414=>"function test()\nusing a\nend",
                :E415=>"function test()\nexport a\nend",
                :E416=>"function test()\nimport a\nend")


Union{Int,AbstractString}

@testset "Testing the linting in practise" begin
    for key in keys(errordic)
        @test lintstr(errordic[key])[1].code == key
    end
end
