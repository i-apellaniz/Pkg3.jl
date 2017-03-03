#!/usr/bin/env julia

using Base.Random: UUID
using Base.Pkg.Types
using Base.Pkg.Reqs: Reqs, Requirement
using Base: thispatch, thisminor, nextpatch, nextminor
using SHA

## General utility functions ##

function invert_map(fwd::Dict{K,V}) where {K,V}
    rev = Dict{V,Vector{K}}()
    for (k, v) in fwd
        push!(get!(rev, v, K[]), k)
    end
    foreach(sort!, values(rev))
    return rev
end

function invert_map(fwd::Dict{Vector{K},V}) where {K,V}
    rev = Dict{V,Vector{K}}()
    for (k, v) in fwd
        append!(get!(rev, v, K[]), k)
    end
    foreach(sort!, values(rev))
    return rev
end

flatten_keys(d::Dict{Vector{K},V}) where {K,V} =
    Dict{K,V}(k => v for (ks, v) in d for k in ks)

## Computing UUID5 values from (namespace, key) pairs ##

function uuid5(namespace::UUID, key::String)
    data = [reinterpret(UInt8, [namespace.value]); Vector{UInt8}(key)]
    u = reinterpret(UInt128, sha1(data)[1:16])[1]
    u &= 0xffffffffffff0fff3fffffffffffffff
    u |= 0x00000000000050008000000000000000
    return UUID(u)
end
uuid5(namespace::UUID, key::AbstractString) = uuid5(namespace, String(key))

const uuid_dns = UUID(0x6ba7b810_9dad_11d1_80b4_00c04fd430c8)
const uuid_julia = uuid5(uuid_dns, "julialang.org")

## Loading data into various data structures ##

struct Require
    versions::VersionInterval
    systems::Vector{Symbol}
end

struct Version
    sha1::String
    julia::VersionInterval
    requires::Dict{String,Require}
end

struct Package
    uuid::UUID
    url::String
    versions::Dict{VersionNumber,Version}
end

function load_requires(path::String)
    requires = Dict{String,Require}()
    isfile(path) || return requires
    for r in filter!(r->r isa Requirement, Reqs.read(path))
        @assert length(r.versions.intervals) == 1
        new = haskey(requires, r.package)
        versions, systems = r.versions.intervals[1], r.system
        if haskey(requires, r.package)
            versions = versions ∩ requires[r.package].versions
            systems  = systems  ∪ requires[r.package].systems
        end
        requires[r.package] = Require(versions, systems)
    end
    return requires
end

function load_versions(dir::String)
    versions = Dict{VersionNumber,Version}()
    isdir(dir) || return versions
    for ver in readdir(dir)
        path = joinpath(dir, ver)
        sha1 = joinpath(path, "sha1")
        isfile(sha1) || continue
        requires = load_requires(joinpath(path, "requires"))
        julia = pop!(requires, "julia", Require(VersionInterval(v"0.1", v"0.6"), []))
        @assert isempty(julia.systems)
        versions[VersionNumber(ver)] = Version(readchomp(sha1), julia.versions, requires)
    end
    return versions
end

function load_packages(dir::String)
    packages = Dict{String,Package}()
    for pkg in readdir(dir)
        path = joinpath(dir, pkg)
        url = joinpath(path, "url")
        versions = joinpath(path, "versions")
        isfile(url) || continue
        packages[pkg] = Package(uuid5(uuid_julia, pkg), readchomp(url), load_versions(versions))
    end
    return packages
end

@eval julia_versions() = $([VersionNumber(0,m) for m=1:5])
julia_versions(f::Function) = filter(f, julia_versions())
julia_versions(vi::VersionInterval) = julia_versions(v->v in vi)

macro clean(ex) :(x = $(esc(ex)); $(esc(:clean)) &= x; x) end

function prune!(packages::Associative{String,Package})
    while true
        clean = true
        filter!(packages) do pkg, p
            filter!(p.versions) do ver, v
                @clean ver == thispatch(ver) > v"0.0.0" &&
                !isempty(julia_versions(v.julia)) &&
                all(v.requires) do kv
                    req, r = kv
                    haskey(packages, req) &&
                    any(w->w in r.versions, keys(packages[req].versions))
                end
            end
            @clean !isempty(p.versions)
        end
        clean && return packages
    end
end

## Functions for representing package version info ##

≲(v::VersionNumber, t::NTuple{0,Int}) = true
≲(v::VersionNumber, t::NTuple{1,Int}) = v.major ≤ t[1]
≲(v::VersionNumber, t::NTuple{2,Int}) = v.major < t[1] ||
                                        v.major ≤ t[1] && v.minor ≤ t[2]
≲(v::VersionNumber, t::NTuple{3,Int}) = v.major < t[1] ||
                                        v.major ≤ t[1] && v.minor < t[2] ||
                                        v.major ≤ t[1] && v.minor ≤ t[2] && v.patch ≤ t[3]

≲(t::NTuple{0,Int}, v::VersionNumber) = true
≲(t::NTuple{1,Int}, v::VersionNumber) = t[1] ≤ v.major
≲(t::NTuple{2,Int}, v::VersionNumber) = t[1] < v.major ||
                                        t[1] ≤ v.major && t[2] ≤ v.minor
≲(t::NTuple{3,Int}, v::VersionNumber) = t[1] < v.major ||
                                        t[1] ≤ v.major && t[2] < v.minor ||
                                        t[1] ≤ v.major && t[2] ≤ v.minor && t[3] ≤ v.patch

function compress_versions(inc::Vector{VersionNumber}, from::Vector{VersionNumber})
    issorted(inc) || (inc = sort(inc))
    exc = sort!(setdiff(from, inc))
    pairs = []
    if isempty(exc)
        lo, hi = first(inc), last(inc)
        push!(pairs, (lo.major, lo.minor) => (hi.major, hi.minor))
    else
        for v in inc
            t = (v.major, v.minor)
            if any(t ≲ w ≲ t for w in exc)
                t = (v.major, v.minor, v.patch)
            end
            if isempty(pairs) || any(pairs[end][1] ≲ w ≲ t for w in exc)
                push!(pairs, t => t) # need a new interval
            else
                pairs[end] = pairs[end][1] => t # can be merged with last
            end
        end
    end
    @assert all(any(p[1] ≲ v ≲ p[2] for p ∈ pairs) for v ∈ inc)
    @assert all(!any(p[1] ≲ v ≲ p[2] for p ∈ pairs) for v ∈ exc)
    return pairs
end
compress_versions(f::Function, from::Vector{VersionNumber}) =
    compress_versions(filter(f, from), from)
compress_versions(vi::VersionInterval, from::Vector{VersionNumber}) =
    compress_versions(v->v in vi, from)
compress_versions(inc, from) = compress_versions(inc, collect(from))

versions_string(p::Pair) = versions_string(p...)
versions_string(a::Tuple{}, b::Tuple{}) = "*"
versions_string(a::NTuple{m,Int}, b::NTuple{n,Int}) where {m,n} =
    a == b ? join(a, '.') : "$(join(a, '.'))-$(join(b, '.'))"

versions_repr(x) = repr(versions_string(x))
versions_repr(v::Vector) = length(v) == 1 ? repr(versions_string(v[1])) :
    "[" * join(map(repr∘versions_string, v), ", ") * "]"

## Preprocessing routines ##

function compat_julia(p::Package)
    fwd = Dict(ver => compress_versions(v.julia, julia_versions()) for (ver, v) in p.versions)
    rev = Dict(jul => compress_versions(vers, keys(fwd)) for (jul, vers) in invert_map(fwd))
    return sort!(collect(flatten_keys(invert_map(rev))), by=first∘first)
end

function compat_versions(p::Package, packages=Main.packages)
    fwd = Dict{String,Dict{VersionNumber,Any}}()
    for (ver, v) in p.versions, (req, r) in v.requires
        d = get!(fwd, req, Dict{VersionNumber,Any}())
        d[ver] = compress_versions(r.versions, keys(packages[req].versions))
    end
    vers = sort!(collect(keys(p.versions)))
    uniform = Dict{String,Vector{Any}}()
    nonunif = Dict{String,Dict{Any,Vector{Any}}}()
    for (req, d) in sort!(collect(fwd), by=lowercase∘first)
        r = Dict(rv => compress_versions(pv, vers) for (rv, pv) in invert_map(d))
        if length(r) == 1 && length(d) == length(vers)
            # same requirements for all pkg versions
            uniform[req] = first(keys(r))
        else
            # different requirements for various versions
            nonunif[req] = flatten_keys(invert_map(r))
        end
    end
    return uniform, nonunif
end

## Package info output routines ##

function print_package_metadata(pkg::String, p::Package; julia=compat_julia(p))
    print("""
    [$pkg]
    uuid = "$(p.uuid)"
    repo = "$(p.url)"
    """)
    if length(julia) == 1
        print("""
        julia = $(versions_repr(julia[1][2]))
        """)
    end
    println()
end

function print_versions_sha1(pkg::String, p::Package)
    print("""
    \t[$pkg.versions.sha1]
    """)
    for (ver, v) in sort!(collect(p.versions), by=first)
        print("""
        \t"$ver" = "$(v.sha1)"
        """)
    end
    println()
end

function print_compat_julia(pkg::String, p::Package; julia=compat_julia(p))
    length(julia) == 1 && return
    print("""
    \t[$pkg.julia]
    """)
    for (versions, julias) in julia
        @assert length(julias) == 1
        print("""
        \t$(versions_repr(versions)) = $(versions_repr(julias))
        """)
    end
    println()
end

# NOTE: UUID mapping is optional. When a dependency is used by name with no
# corresponding UUID mapping, then the current meaning of this name in the same
# registry is assumed. If no UUID mappings are present, the section may be
# skipped entirely. If a package has a dependency which is not registered in the
# same registry, then it  must include a UUID mapping entry for that dependency.

# This code doesn't emit this, but if a dependency name is used to refer to
# different packages across different versions of a package, then this is
# expressed by associating the name with a `version => uuid` table instead of
# just a single UUID value.

function print_compat_uuids(pkg::String, p::Package; packages=Main.packages)
    print("""
    \t[$pkg.compat.uuids]
    """)
    pkgs = Set{String}()
    for (ver, v) in p.versions
        union!(pkgs, keys(v.requires))
    end
    for pkg in sort!(collect(pkgs), by=lowercase)
        print("""
        \t$pkg = "$(packages[pkg].uuid)"
        """)
    end
    println()
end

function print_compat_versions(pkg::String, p::Package; packages=Main.packages)
    uniform, nonunif = compat_versions(p, packages)
    if !isempty(uniform)
        print("""
        \t[$pkg.compat.versions]
        """)
        for (req, v) in sort!(collect(uniform), by=lowercase∘first)
            print("""
            \t$req = $(versions_repr(v))
            """)
        end
        println()
    end
    for (req, r) in sort!(collect(nonunif), by=lowercase∘first)
        print("""
        \t[$pkg.compat.versions.$req]
        """)
        for (pv, rv) in sort!(collect(r), by=first∘first)
            print("""
            \t$(versions_repr(pv)) = $(versions_repr(rv))
            """)
        end
        println()
    end
end

## Load package data and generate registry ##

dir = length(ARGS) >= 1 ? ARGS[1] : Pkg.dir("METADATA")
packages = load_packages(dir)
prune!(packages)

if !isinteractive()
    for (pkg, p) in sort!(collect(packages), by=lowercase∘first)
        julia = compat_julia(p)
        print_package_metadata(pkg, p, julia=julia)
        print_versions_sha1(pkg, p)
        print_compat_julia(pkg, p, julia=julia)
        # NOTE: because of optional UUID mapping, this section is totally
        # unnecessary while translating metadata. We could however, represent
        # the Stats => StatsBase rename correctly.
        false && print_compat_uuids(pkg, p)
        print_compat_versions(pkg, p)
    end
end
