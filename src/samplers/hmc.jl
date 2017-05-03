doc"""
    HMC(n_samples::Int, lf_size::Float64, lf_num::Int)

Hamiltonian Monte Carlo sampler.

Usage:

```julia
HMC(1000, 0.05, 10)
```

Example:

```julia
@model example begin
  ...
end

sample(example, HMC(1000, 0.05, 10))
```
"""
immutable HMC <: InferenceAlgorithm
  n_samples ::  Int       # number of samples
  lf_size   ::  Float64   # leapfrog step size
  lf_num    ::  Int       # leapfrog step number
  space     ::  Set       # sampling space, emtpy means all
  gid       ::  Int
  function HMC(lf_size::Float64, lf_num::Int, space...)
    HMC(1, lf_size, lf_num, space..., 0)
  end
  function HMC(n_samples, lf_size, lf_num)
    new(n_samples, lf_size, lf_num, Set(), 0)
  end
  function HMC(n_samples, lf_size, lf_num, space...)
    space = isa(space, Symbol) ? Set([space]) : Set(space)
    new(n_samples, lf_size, lf_num, space, 0)
  end
  HMC(alg::HMC, new_gid::Int) = new(alg.n_samples, alg.lf_size, alg.lf_num, alg.space, new_gid)
end

typealias Hamiltonian Union{HMC,HMCDA,NUTS}

Sampler(alg::Hamiltonian) = begin
  info = Dict{Symbol, Any}()
  Sampler(alg, info)
end

function step(model, spl::Sampler{HMC}, vi::VarInfo, is_first::Bool)
  if is_first
    true, vi
  else
    # Set parameters
    ϵ, τ = spl.alg.lf_size, spl.alg.lf_num

    p = sample_momentum(vi, spl)

    dprintln(3, "X -> R...")
    if spl.alg.gid != 0 vi = link(vi, spl) end

    dprintln(2, "recording old H...")
    oldH = find_H(p, model, vi, spl)

    dprintln(2, "leapfrog stepping...")
    vi, p, _ = leapfrog(vi, p, τ, ϵ, model, spl)

    dprintln(2, "computing new H...")
    H = find_H(p, model, vi, spl)

    dprintln(2, "computing ΔH...")
    ΔH = H - oldH

    dprintln(3, "R -> X...")
    if spl.alg.gid != 0 vi = invlink(vi, spl); cleandual!(vi) end

    dprintln(2, "decide wether to accept...")
    if ΔH < 0 || rand() < exp(-ΔH)      # accepted
      true, vi
    else                                # rejected
      false, vi
    end
  end
end

sample(model::Function, alg::Hamiltonian) = sample(model, alg, CHUNKSIZE)

# NOTE: in the previous code, `sample` would call `run`; this is
# now simplified: `sample` and `run` are merged into one function.
function sample{T<:Hamiltonian}(model::Function, alg::T, chunk_size::Int)
  global CHUNKSIZE = chunk_size;
  spl = Sampler(alg);
  alg_str = isa(alg, HMC)   ? "HMC"   :
            isa(alg, HMCDA) ? "HMCDA" :
            isa(alg, NUTS)  ? "NUTS"  : "Hamiltonian"

  # initialization
  n =  spl.alg.n_samples
  samples = Array{Sample}(n)
  weight = 1 / n
  for i = 1:n
    samples[i] = Sample(weight, Dict{Symbol, Any}())
  end
  accept_num = 0    # record the accept number
  vi = model()

  if spl.alg.gid == 0 vi = link(vi, spl) end

  # HMC steps
  @showprogress 1 "[$alg_str] Sampling..." for i = 1:n
    dprintln(2, "recording old θ...")
    old_vi = deepcopy(vi)
    dprintln(2, "$alg_str stepping...")
    is_accept, vi = step(model, spl, vi, i==1)
    if is_accept    # accepted => store the new predcits
      samples[i].value = Sample(vi).value
      accept_num = accept_num + 1
    else            # rejected => store the previous predcits
      vi = old_vi
      samples[i] = samples[i - 1]
    end
  end

  accept_rate = accept_num / n    # calculate the accept rate

  println("[$alg_str] Done with accept rate = $accept_rate.")

  Chain(0, samples)    # wrap the result by Chain
end

function assume{T<:Hamiltonian}(spl::Sampler{T}, dist::Distribution, vn::VarName, vi::VarInfo)
  dprintln(2, "assuming...")
  updategid!(vi, vn, spl)
  r = vi[vn]
  vi.logp += logpdf(dist, r, istransformed(vi, vn))
  r
end

function observe{T<:Hamiltonian}(spl::Sampler{T}, d::Distribution, value, vi::VarInfo)
  dprintln(2, "observing...")
  vi.logp += logpdf(d, map(x -> Dual(x), value))
end
