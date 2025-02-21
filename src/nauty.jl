mutable struct NautyOptions
    getcanon::Cint
    digraph::Cbool
    writeautoms::Cbool
    writemarkers::Cbool
    defaultptn::Cbool
    cartesian::Cbool
    linelength::Cint

    outfile::Ptr{Cvoid}
    userrefproc::Ptr{Cvoid}
    userautomproc::Ptr{Cvoid}
    userlevelproc::Ptr{Cvoid}
    usernodeproc::Ptr{Cvoid}
    usercanonproc::Ptr{Cvoid}
    invarproc::Ptr{Cvoid}

    tc_level::Cint
    mininvarlevel::Cint
    maxinvarlevel::Cint
    invararg::Cint

    dispatch::Ptr{Cvoid}

    schreier::Cbool
    extra_options::Ptr{Cvoid}

    NautyOptions() = new(
        0, false, false, false, true, false, 78,
        C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL,
        100, 0, 1, 0,
        C_NULL,
        false, C_NULL
    )
end
mutable struct NautyStatistics
    grpsize1::Cdouble
    grpsize2::Cint
    numorbits::Cint
    numgenerators::Cint
    errstatus::Cint
    numnodes::Culong
    numbadleaves::Culong
    maxlevel::Cint
    tctotal::Culong
    canupdates::Culong
    invapplics::Culong
    invsuccesses::Culong
    invarsuclevel::Cint

    NautyStatistics() = new(
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
end

# TODO: Make this useful
# struct AutomorphismGroup{T<:Integer}
#     n::T
#     orbits::Vector{T}
#     generators::T
#     # ... 
# end


"""
    nauty(g::DenseNautyGraph, canonical_form=true; ignore_vertex_labels=false, kwargs...)

Compute a graph g's automorphism group and its canonical form.
"""
function nauty(g::DenseNautyGraph, canonical_form=true; ignore_vertex_labels=false, kwargs...) # TODO: allow nautyoptions to be overwritten
    n, m = g.n_vertices, g.n_words

    options = NautyOptions() # TODO: allocate default options outside and make sure they do not interfere with multithreading
    options.dispatch = cglobal((:dispatch_graph, libnauty), Cvoid)
    options.getcanon = canonical_form
    options.digraph = is_directed(g)
    options.defaultptn = ignore_vertex_labels || all(iszero, g.labels) # TODO: check more carefully if lab/ptn is valid

    stats = NautyStatistics()

    lab, ptn = _vertexlabels_to_labptn(g.labels)

    orbits = zeros(Cint, n)
    h = zero(g.graphset)

    @ccall libnauty.densenauty(
        g.graphset::Ref{WordType},
        lab::Ref{Cint},
        ptn::Ref{Cint},
        orbits::Ref{Cint},
        Ref(options)::Ref{NautyOptions},
        Ref(stats)::Ref{NautyStatistics},
        m::Cint,
        n::Cint,
        h::Ref{WordType})::Cvoid

    # TODO: clean this up
    if stats.grpsize1 * 10^stats.grpsize2 < typemax(Int)
        grpsize = round(Int, stats.grpsize1 * 10^stats.grpsize2)
    else
        @warn "automorphism group size overflow"
        grpsize = 0
    end
    
    # autmorph = AutomorphismGroup{T}(grpsize, orbits, stats.numgenerators) # TODO: summarize useful automorphism group info

    if canonical_form
        canong = h
        canon_perm = lab .+ 1
    else
        canong = nothing
        canon_perm = nothing
    end
    return grpsize, canong, canon_perm, orbits
end

function _nautyhash(g::DenseNautyGraph)
    grpsize, canong, canon_perm, orbits = nauty(g, true)

    # Base.hash skips elements in arrays of length >= 8192
    # Use SHA in these cases
    canong_hash = length(canong) >= 8192 ? hash_sha(canong) : hash(canong)
    labels_hash = @views length(g.labels) >= 8192 ? hash_sha(g.labels[canon_perm]) : hash(g.labels[canon_perm])

    hashval = hash(labels_hash, canong_hash)

    g.hashval = hashval
    g.orbits = orbits

    return grpsize, canong, canon_perm, hashval, orbits
end


"""
    canonize!(g::AbstractNautyGraph)

Reorder g's vertices to be in canonical order. Returns the permutation used to canonize g and the automorphism group size.
"""
function canonize!(g::AbstractNautyGraph)
    grpsize, canong, canon_perm, hashval, orbits = _nautyhash(g)
    copyto!(g.graphset, canong)
    permute!(g.labels, canon_perm)
    return canon_perm, grpsize
end

"""
    is_isomorphic(g::AbstractNautyGraph, h::AbstractNautyGraph)

Check whether two graphs g and h are isomorphic to each other by comparing their canonical forms.
"""
function is_isomorphic(g::AbstractNautyGraph, h::AbstractNautyGraph)
    _, canong, permg = nauty(g, true)
    _, canonh, permh = nauty(h, true)
    return canong == canonh && view(g.labels, permg) == view(h.labels, permh)
end
≃(g::AbstractNautyGraph, h::AbstractNautyGraph) = is_isomorphic(g, h)



"""
    ghash(g::AbstractNautyGraph)

Hash the canonical version of g, so that (up to hash collisions) `ghash(g1) == ghash(g2)` implies `is_isomorphic(g1, g2) == true`.
Hashes are computed using `Base.hash` for small graphs (nv < 8192), or using the first 64 bits of `sha256` for larger graphs.
"""
function ghash(g::AbstractNautyGraph)
    if !isnothing(g.hashval)
        return g.hashval
    end

    _, _, _, hashval, _ = _nautyhash(g)

    # I think this is not useful here since it is part of the _nautyhash function
    g.hashval = hashval
    
    return g.hashval
end

"""
    orbit(g::AbstractNautyGraph)

Find the orbits of g based on its automorphism group. 
"""
function orbits(g::AbstractNautyGraph)
    if !isnothing(g.orbits)
        return g.orbits
    end

    _, _, _, _, orbits = _nautyhash(g)

    # I think this is not useful here since it is part of the _nautyhash function
    g.orbits = orbits
    
    return g.orbits
end

# TODO: decide what the default equality comparision should be
Base.hash(g::DenseNautyGraph, h::UInt) = hash(g.labels, hash(g.graphset, h))
Base.:(==)(g::DenseNautyGraph, h::DenseNautyGraph) = (g.graphset == h.graphset) && (g.labels == h.labels)
