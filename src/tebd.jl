export apply_gate!,
    tebd!, TEBD2,
    TEBD2Sweep, TEBD4

abstract type TEBDalg end

"""
    TEBD2 <: TEBDalg
TEBD using 2nd order Trotter decomposition of the time evolution
operator. Namely, if the Hamiltonian is given by ``\\sum_i h_{i,i+1}`` with
``h_{i,i+1}`` having support only on the sites ``i,i+1``, define
``H_{e} = \\sum_{i \\el \\mathrm{even}}, H_{o} = \\sum_{i \\el \\mathrm{odd}}``.
The time-evolution operator is then approximated as:

``U(\\Delta t) = \\exp(-i \\Delta t/2 H_{o}) \\exp(-i \\Delta t H_{e}) \\exp(-i \\Delta t/2 H_{o})``

In practice the ``\\Delta t/2 H_{o}`` terms from consecutive time steps are grouped together as long as
no measurement is performed. Hence the overhead with respect to 1st order Trotter decomposition is
minimal.

The Trotter error per time step is ``O(\\Delta t^2)``.
"""
struct TEBD2 <: TEBDalg
end

"""
    TEBD2Sweep <: TEBDalg
TEBD using a 2nd Trotter decomposition similar to [`TEBD2`](@ref), but
instead of an even-odd decomposition of the Hamiltonian the time evolution
operator is approximated as:

``U(\\Delta t) = e^{-i \\Delta t /2 h_{1,2} } e^{-i \\Delta t /2 h_{2,3}} ... e^{-i \\Delta t /2 h_{2,3}} e^{-i \\Delta t /2 h_{1,2} }``

That is the exponentials of the bond Hamiltonians are applied to each bond sweeping from left to right and then applied a second
time sweeping from right to left.

The Trotter error per time step is ``O(\\Delta t^2)``
"""
struct TEBD2Sweep <: TEBDalg
end


"""
    TEBD4 <: TEBDalg
TEBD using a 4th order Trotter decomposition.
The time-evolution operator is approximated as ``U(τ₁)U(τ₂)U(τ₃)U(τ₂)U(τ₁)``
with ``U(τᵢ) = exp(-iH_o τᵢ/2) exp(-i H_e τᵢ ) exp(-i H_o τᵢ/2)``,
and ``τ1=τ2=1/(4-4^(1/3)) dt, τ3=dt - 4 τ1``.

A reduction in the number of gate applications is achieved by grouping together
the ``exp(-iH_o τᵢ/2)`` terms from consecutive Us and time-steps (except at measurement times).
"""
struct TEBD4 <: TEBDalg
end

function time_evo_gates(dt, H::GateList, alg::TEBD2)
    Uhalf = exp.(-1im*dt/2 .* H[1:2:end])
    Us = [exp.( -1im*dt .* H[2:2:end]), exp.(-1im*dt .* H[1:2:end])]
    return [Uhalf ], Us, [Us[1], Uhalf]
end

function time_evo_gates(dt,H::GateList,alg::TEBD2Sweep)
    Us = [exp.(-1im*dt/2 .* H), exp.(-1im*dt/2 .* H)]
    return [], Us, []
end

function time_evo_gates(dt,H::GateList,alg::TEBD4)
    τ₁ = 1/(4-4^(1/3))*dt
    τ₂ = τ₁
    τ₃ = dt - 2*τ₁ - 2*τ₂

    e= 2:2:length(H)
    o = 1:2:length(H)
    Ustart = [exp.(-1im*τ₁/2 .* H[o])]

    sequence = [(τ₁, e), (τ₁, o ), (τ₂,e), ((τ₂+τ₃)/2, o), (τ₃, e),
                ((τ₂+τ₃)/2, o), (τ₂,e), (τ₂,o), (τ₁,e), (τ₁,o)]
    Us = map(x->exp.(-1im*x[1] .* H[x[2]]), sequence)

    end_sequence = [(τ₁, e), (τ₁, o ), (τ₂,e), ((τ₂+τ₃)/2, o), (τ₃, e),
                    ((τ₂+τ₃)/2, o), (τ₂,e), (τ₂,o), (τ₁,e), (τ₁/2,o)]
    Uend = map(x->exp.(-1im*x[1] .* H[x[2]]), end_sequence)

    return Ustart, Us , Uend
end

tebd!(psi::MPS,H::BondOperator, args...; kwargs...) = tebd!(psi,gates(H),args...;kwargs...)

function tebd!(psi::MPS, H::GateList, dt::Number, tf::Number, alg::TEBDalg = TEBD2() ; kwargs... )
    # TODO: think of the best way to avoid inexact error when dt is very small
    # one option would be to use round(tf/dt) and verify that abs(round(tf/dt)-tf/dt)
    # is smaller than some threshold. Another option would be to use big(Rational(dt)).
    nsteps = Int(tf/dt)
    obs = get(kwargs,:observer, NoTEvoObserver())
    orthogonalize_step = get(kwargs,:orthogonalize,0)

    #We can bunch together half-time steps, when we don't need to measure observables
    dtm = measurement_dt(obs)
    if dtm > 0
        floor(dtm / dt) != dtm /dt && throw("Measurement time step $dtm incommensurate with time-evolution time step $dt")
        mstep = floor(dtm / dt)
        nbunch = gcd(mstep,nsteps)
    else
        nbunch = nsteps
    end
    orthogonalize_step > 0 && (nbunch = gcd(nbunch,orthogonalize_step))

    Ustart, Us, Uend = time_evo_gates(dt,H,alg)

    length(Ustart)==0 && length(Uend)==0 && (nbunch+=1)

    step = 0
    switchdir(dir) =dir== "fromleft" ? "fromright" : "fromleft"
    dir = "fromleft"
    while step < nsteps
        for U in Ustart
            apply_gates!(psi, U ; dir = dir, kwargs...)
            dir = switchdir(dir)
        end

        for i in 1:nbunch-1
            for U in Us
                apply_gates!(psi,U; dir=dir, kwargs...)
                dir = switchdir(dir)
            end
            step += 1
            observe!(obs,psi,t=step*dt)
            checkdone!(obs,psi) && break
        end

        #finalize the last time step from the bunched steps
        for U in Uend
            apply_gates!(psi,U; dir=dir, kwargs...)
            dir = switchdir(dir)
        end

        length(Uend)>0 && (step += 1)
        (orthogonalize_step>0 && step % orthogonalize_step ==0) && reorthogonalize!(psi)
        observe!(obs,psi, t=step*dt)
        checkdone!(obs,psi) && break
    end
    return psi
end


