export produce_or_load, tagsave, @tagsave, safesave

"""
    produce_or_load([path="",] c, f; kwargs...) -> file, s
Let `s = joinpath(path, savename(prefix, c, suffix))`.
If a file named `s` exists then load it and return it, along
with the global path that it is saved at (`s`).

If the file does not exist then call `file = f(c)`, with `f` your function
that produces your data. Then save `file` as `s` and then return `file, s`.
The function `f` must return a dictionary,
the macros [`@dict`](@ref) and [`@strdict`](@ref) can help with that.

You can use [do-block]
(https://docs.julialang.org/en/v1/manual/functions/#Do-Block-Syntax-for-Function-Arguments)
instead of defining a function to pass in. For example,
```julia
produce_or_load([path="",] c) do c
    # simulation wiht config `c` runs here
end
```

## Keywords
* `suffix = "jld2", prefix = default_prefix(c)` : Used in [`savename`](@ref).
* `tag::Bool = istaggable(suffix)` : Save the file using [`tagsave`](@ref) if `true`.
* `gitpath, storepatch` : Given to [`tagsave`](@ref) if `tag` is `true`.
* `force = false` : If `true` then don't check if file `s` exists and produce
  it and save it anyway.
* `loadfile = true` : If `false`, this function does not actually load the
  file, but only checks if it exists. The return value in this case is always
  `nothing, s`, regardless of whether the file exists or not. If it doesn't
  exist it is still produced and saved.
* `verbose = true` : print info about the process, if the file doesn't exist.
* `kwargs...` : All other keywords are propagated to `savename`.
"""
produce_or_load(c, f; kwargs...) = produce_or_load("", c, f; kwargs...)
produce_or_load(f::Function, c; kwargs...) = produce_or_load(c, f; kwargs...)
produce_or_load(f::Function, path, c; kwargs...) = produce_or_load(path, c, f; kwargs...)
function produce_or_load(path, c, f::Function;
    suffix = "jld2", prefix = default_prefix(c),
    tag::Bool = istaggable(suffix), gitpath = projectdir(), loadfile = true,
    force = false, verbose = true, storepatch = true, kwargs...)

    s = joinpath(path, savename(prefix, c, suffix; kwargs...))

    if !force && isfile(s)
        if loadfile
            file = wload(s)
            return file, s
        else
            return nothing, s
        end
    else
        if force
            verbose && @info "Producing file $s now..."
        else
            verbose && @info "File $s does not exist. Producing it now..."
        end
        file = f(c)
        try
            if tag
                tagsave(s, file; safe = false, gitpath = gitpath, storepatch = storepatch)
            else
                wsave(s, copy(file))
            end
            verbose && @info "File $s saved."
        catch er
            @warn "Could not save file. Error stacktrace:"*
            Base.showerror(stderr, er, stacktrace(catch_backtrace()))
        end
        if loadfile
            return file, s
        else
            return nothing, s
        end
    end
end

################################################################################
#                             tag saving                                       #
################################################################################
"""
    tagsave(file::String, d::Dict; safe = false, gitpath = projectdir(), storepatch = true, force = false)
First [`tag!`](@ref) dictionary `d` and then save `d` in `file`.
If `safe = true` save the file using [`safesave`](@ref).

"Tagging" means that when saving the dictionary, an extra field
`:gitcommit` is added to establish reproducibility of results using
Git. If the Git repository is dirty, one more field `:gitpatch` is
added that stores the difference string.  If a dictionary already
contains a key `:gitcommit`, it is not overwritten, unless,
`force=true`. For more details, see [`tag!`](@ref).
"""
function tagsave(file, d; safe::Bool = false, gitpath = projectdir(), storepatch = true, force = false, source = nothing)
    d2 = tag!(d, gitpath=gitpath, storepatch=storepatch, force=force, source=source)
    if safe
        safesave(file, copy(d2))
    else
        wsave(file, copy(d2))
    end
    return d2
end


"""
    @tagsave(file::String, d::Dict; kwargs...)
Same as [`tagsave`](@ref) but one more field `:script` is added that records
the local path of the script and line number that called `@tagsave`, see [`@tag!`](@ref).
"""
macro tagsave(file,d,args...)
    args = Any[args...]
    # Keywords added after a ; are moved to the front of the expression
    # that is passed to the macro. So instead of getting the filename in file
    # an Expr is passed.
    if file isa Expr && file.head == :parameters
        length(args) > 0 || return :(throw(MethodError(@tagsave,$(esc(file)),$(esc(d)),$(esc.(args)...))))
        extra_kw_def = file.args
        file = d
        d = popfirst!(args)
        append!(args,extra_kw_def)
    end
    s = QuoteNode(__source__)
    return :(tagsave($(esc(file)), $(esc(d)), $(esc.(convert_to_kw.(args))...),source=$s))
end

################################################################################
#                          Backup files before saving                          #
################################################################################

# Implementation inspired by behavior of GROMACS
"""
    safesave(filename, data)

Safely save `data` in `filename` by ensuring that no existing files
are overwritten. Do this by renaming already existing data with a backup-number
ending like `#1, #2, ...`. For example if `filename = test.jld2`, the first
time you `safesave` it, the file is saved normally. The second time
the existing save is renamed to `test_#1.jld2` and a new file `test.jld2`
is then saved.

If a backup file already exists then its backup-number is incremented
(e.g. going from `#2` to `#3`). For example safesaving `test.jld2` a third time
will rename the old `test_#1.jld2` to `test_#2.jld2`, rename the old
`test.jld2` to `test_#1.jld2` and then save a new `test.jld2` with the latest
`data`.

See also [`tagsave`](@ref).
"""
function safesave(f, data)
    recursively_clear_path(f)
    wsave(f, data)
end

#take a path of a results file and increment its prefix backup number
function increment_backup_num(filepath)
    path, filename = splitdir(filepath)
    fname, suffix = splitext(filename)
    m = match(r"^(.*)_#([0-9]+)$", fname)
    if m == nothing
        return joinpath(path, "$(fname)_#1$(suffix)")
    end
    newnum = string(parse(Int, m.captures[2]) +1)
    return joinpath(path, "$(m.captures[1])_#$newnum$(suffix)")
end

#recursively move files to increased backup number
function recursively_clear_path(cur_path)
    isfile(cur_path) || return
    new_path=increment_backup_num(cur_path)
    if isfile(new_path)
        recursively_clear_path(new_path)
    end
    mv(cur_path, new_path)
end

################################################################################
#                    Compliment to dict_list: tmpsave                          #
################################################################################
export tmpsave
using Random
"""
    tmpsave(dicts::Vector{Dict} [, tmp]; kwargs...) -> r
Save each entry in `dicts` into a unique temporary file in the directory `tmp`.
Then return the list of file names (relative to `tmp`) that were used
for saving each dictionary. Each dictionary can then be loaded back by calling

    FileIO.load(nth_tmpfilename, "params")

`tmp` defaults to `projectdir("_research", "tmp")`.

See also [`dict_list`](@ref).

## Keywords
* `l = 8` : number of characters in the random string.
* `prefix = ""` : prefix each temporary name will have.
* `suffix = "jld2"` : ending of the temporary names (no need for the dot).
"""
function tmpsave(dicts, tmp = projectdir("_research", "tmp");
    l = 8, suffix = "jld2", prefix = "")

    mkpath(tmp)
    n = length(dicts)
    existing = readdir(tmp)
    r = String[]
    i = 0
    while i < n
        x = prefix*randstring(l)*"."*suffix
        while x ∈ r || x ∈ existing
            x = prefix*randstring(l)*"."*suffix
        end
        i += 1
        push!(r, x)
        wsave(joinpath(tmp, x), Dict("params" => copy(dicts[i])))
    end
    r
end
