## initialize!

@muladd function initialize!(nlsolver::NLSolver{<:NLFunctional}, integrator)
  nlsolver.cache.tstep = integrator.t + nlsolver.c * integrator.dt

  nothing
end

@muladd function initialize!(nlsolver::NLSolver{<:NLAnderson}, integrator)
  @unpack cache = nlsolver

  cache.history = 0
  cache.tstep = integrator.t + nlsolver.c * integrator.dt

  nothing
end

## initial_η

function initial_η(nlsolver::NLSolver{<:Union{NLFunctional,NLAnderson}}, integrator)
  nlsolver.ηold
end

## compute_step!

"""
    compute_step!(nlsolver::NLSolver{<:Union{NLFunctional,NLAnderson}}, integrator)

Compute the next step of the fixed-point iteration
```math
g(z) = dt⋅f(tmp + γ⋅z, p, t + c⋅dt),
```
and return the norm of ``g(z) - z``.

# References

Ernst Hairer and Gerhard Wanner, "Solving Ordinary Differential
Equations II, Springer Series in Computational Mathematics. ISBN
978-3-642-05221-7. Section IV.8.
[doi:10.1007/978-3-642-05221-7](https://doi.org/10.1007/978-3-642-05221-7).
"""
function compute_step!(nlsolver::NLSolver{<:NLFunctional}, integrator)
  compute_step_fixedpoint!(nlsolver, integrator)
end

@muladd function compute_step!(nlsolver::NLSolver{<:NLAnderson,false}, integrator)
  @unpack cache = nlsolver
  @unpack aa_start = cache

  # perform Anderson acceleration
  previter = nlsolver.iter - 1
  if previter == aa_start
    # update cached values for next step of Anderson acceleration
    cache.dzold = cache.dz
    cache.z₊old = nlsolver.z
  elseif previter > aa_start
    # actually perform Anderson acceleration
    nlsolver.z = anderson(nlsolver.z, cache)
    if DiffEqBase.has_destats(integrator)
      integrator.destats.nsolve += 1
    end  
  end

  # compute next step
  compute_step_fixedpoint!(nlsolver, integrator)
end

@muladd function compute_step!(nlsolver::NLSolver{<:NLAnderson,true}, integrator)
  @unpack cache = nlsolver
  @unpack aa_start = cache

  # perform Anderson acceleration
  previter = nlsolver.iter - 1
  if previter == aa_start
    # update cached values for next step of Anderson acceleration
    @.. cache.dzold = cache.dz
    @.. cache.z₊old = nlsolver.z
  elseif previter > aa_start
    # actually perform Anderson acceleration
    anderson!(nlsolver.z, cache)
    if DiffEqBase.has_destats(integrator)
      integrator.destats.nsolve += 1
    end  
  end

  # compute next step
  compute_step_fixedpoint!(nlsolver, integrator)
end

@muladd function compute_step_fixedpoint!(nlsolver::NLSolver{<:Union{NLFunctional,
                                                                     NLAnderson},false},
                                          integrator)
  @unpack uprev,t,p,dt,opts = integrator
  @unpack z,γ,cache = nlsolver
  @unpack tstep = cache

  mass_matrix = integrator.f.mass_matrix
  f = nlsolve_f(integrator)

  ustep = @.. nlsolver.tmp + γ*z
  if mass_matrix == I
    ztmp = dt .* f(ustep, p, tstep)
    dz = ztmp .- z
  else
    ztmp = _reshape(mass_matrix * _vec(z), axes(z))
    dz = dt .* f(ustep, p, tstep) .- ztmp
    ztmp = z .+ dz
  end
  if DiffEqBase.has_destats(integrator)
    integrator.destats.nf += 1
  end

  # compute norm of residuals
  atmp = calculate_residuals(dz, uprev, ustep, opts.abstol, opts.reltol, opts.internalnorm, t)
  ndz = opts.internalnorm(atmp, t)

  # cache results
  nlsolver.ztmp = ztmp
  if isdefined(cache, :dz)
    cache.dz = dz
  end

  ndz
end

@muladd function compute_step_fixedpoint!(nlsolver::NLSolver{<:Union{NLFunctional,
                                                                     NLAnderson},true},
                                          integrator)
  @unpack uprev,t,p,dt,opts = integrator
  @unpack z,tmp,ztmp,γ,cache = nlsolver
  @unpack ustep,tstep,k,atmp,dz = cache

  mass_matrix = integrator.f.mass_matrix
  f = nlsolve_f(integrator)

  @.. ustep = tmp + γ*z
  f(k, ustep, p, tstep)
  if DiffEqBase.has_destats(integrator)
    integrator.destats.nf += 1
  end
  if mass_matrix == I
    @.. ztmp = dt * k
    @.. dz = ztmp - z
  else
    mul!(vec(ztmp), mass_matrix, vec(z))
    @.. dz = dt * k - ztmp
    @.. ztmp = z + dz
  end

  # compute norm of residuals
  calculate_residuals!(atmp, dz, uprev, ustep, opts.abstol, opts.reltol, opts.internalnorm, t)
  ndz = opts.internalnorm(atmp, t)

  ndz
end

## resize!

function Base.resize!(nlcache::NLFunctionalCache, i::Int)
  resize!(nlcache.ustep, i)
  resize!(nlcache.k, i)
  resize!(nlcache.atmp, i)
  resize!(nlcache.dz, i)
  nothing
end

function Base.resize!(nlcache::NLAndersonCache, nlsolver::NLSolver{<:NLAnderson},
                      integrator, i::Int)
  resize!(nlcache, nlsolver.alg, i)
end

function Base.resize!(nlcache::NLAndersonCache, nlalg::NLAnderson, i::Int)
  @unpack z₊old,Δz₊s = nlcache

  resize!(nlcache.ustep, i)
  resize!(nlcache.k, i)
  resize!(nlcache.atmp, i)
  resize!(nlcache.dz, i)
  resize!(nlcache.dzold, i)
  resize!(z₊old, i)

  # update history of Anderson cache
  max_history_old = length(Δz₊s)
  max_history = min(nlalg.max_history, nlalg.max_iter, i)

  resize!(nlcache.γs, max_history)
  resize!(nlcache.Δz₊s, max_history)

  if max_history != max_history_old
    nlcache.Q = typeof(nlcache.Q)(undef, i, max_history)
    nlcache.R = typeof(nlcache.R)(undef, max_history, max_history)
  end

  max_history = length(Δz₊s)
  if max_history > max_history_old
    for i in (max_history_old + 1):max_history
      Δz₊s[i] = zero(z₊old)
    end
  end

  nothing
end