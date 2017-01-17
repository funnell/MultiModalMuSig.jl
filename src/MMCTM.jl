type IMMCTM
    K::Vector{Int}          # topics
    D::Int                  # documents
    N::Vector{Vector{Int}}  # observations per document modality
    M::Int                  # modalities
    V::Vector{Int}          # vocab items per modality

    μ::Vector{Float64}
    Σ::Matrix{Float64}
    invΣ::Matrix{Float64}
    α::Vector{Float64}

    ζ::Vector{Vector{Float64}}
    θ::Vector{Vector{Matrix{Float64}}}
    λ::Vector{Vector{Float64}}
    ν::Vector{Vector{Float64}}
    γ::Vector{Vector{Vector{Float64}}}
    Elnϕ::Vector{Vector{Vector{Float64}}}

    X::Vector{Vector{Matrix{Int}}}

    converged::Bool
    elbo::Float64
    ll::Vector{Float64}

    function IMMCTM(k::Vector{Int}, α::Vector{Float64},
            X::Vector{Vector{Matrix{Int}}})
        model = new()

        model.K = k
        model.α = α
        model.X = X

        model.D = length(X)
        model.M = length(features)
        model.V = [
            maximum(maximum(X[d][m][:, 1]) for d in 1:model.D)
            for m in 1:model.M
        ]
        model.N = [[sum(X[d][m][:, 2]) for m in 1:model.M] for d in 1:model.D]

        MK = sum(model.K)

        model.μ = zeros(MK)
        model.Σ = eye(MK)
        model.invΣ = eye(MK)

        model.θ = [
            [
               rand(Dirichlet(model.K[m], 1.0 / model.K[m]), size(X[d][m])[1])
                for m in 1:model.M
            ] for d in 1:model.D
        ]

        model.γ = [
            [Array(Float64, model.V[m]) for k in 1:model.K[m]]
            for m in 1:model.M
        ]
        model.Elnϕ = deepcopy(model.γ)
        update_γ!(model)

        model.λ = [randn(MK) for d in 1:model.D]
        model.ν = [ones(MK) for d in 1:model.D]

        model.ζ = [Array(Float64, model.M) for d in 1:model.D]
        for d in 1:model.D update_ζ!(model, d) end

        model.converged = false

        return model
    end
end

function λ_objective(λ::Vector{Float64}, ∇λ::Vector{Float64},
        ν::Vector{Float64}, Ndivζ::Vector{Float64}, sumθ::Vector{Float64},
        μ::Vector{Float64}, invΣ::Matrix{Float64})

    diff = λ .- μ
    Eeη = exp(λ .+ 0.5ν)

    if length(∇λ) > 0
        ∇λ .= -invΣ * diff .+ sumθ .- Ndivζ .* Eeη
    end

    return -0.5 * (diff' * invΣ * diff)[1] + sum(λ .* sumθ) - sum(Ndivζ .* Eeη)
end

function calculate_sumθ(model::IMMCTM, d::Int)
    return vcat(
        [
            vec(sum(model.θ[d][m] .* model.X[d][m][:, 2]', 2))
            for m in 1:model.M
        ]...
    )
end

function calculate_Ndivζ(model::IMMCTM, d::Int)
    return vcat(
        [
            fill(model.N[d][m] / model.ζ[d][m], model.K[m]) for m in 1:model.M
        ]...
    )
end

function update_λ!(model::IMMCTM, d::Int)
    opt = Opt(:LD_MMA, sum(model.K))
    lower_bounds!(opt, -20.0)
    upper_bounds!(opt, 20.0)
    xtol_rel!(opt, 1e-4)
    xtol_abs!(opt, 1e-4)

    Ndivζ = calculate_Ndivζ(model, d)
    sumθ = calculate_sumθ(model, d)

    max_objective!(
        opt,
        (λ, ∇λ) -> λ_objective(
            λ, ∇λ, model.ν[d], Ndivζ, sumθ, model.μ, model.invΣ
        )
    )
    (optobj, optλ, ret) = optimize(opt, model.λ[d])
    model.λ[d] .= optλ
end

function ν_objective(ν::Vector{Float64}, ∇ν::Vector{Float64},
        λ::Vector{Float64}, Ndivζ::Vector{Float64}, μ::Vector{Float64},
        invΣ::Matrix{Float64})

    Eeη = exp(λ .+ 0.5ν)

    if length(∇ν) > 0
        ∇ν .= -0.5diag(invΣ) .- (Ndivζ / 2) .* Eeη .+ (1 ./ (2ν))
    end

    return -0.5 * trace(diagm(ν) * invΣ) - sum(Ndivζ .* Eeη) + sum(log(ν)) / 2
end

function update_ν!(model::IMMCTM, d::Int)
    opt = Opt(:LD_MMA, sum(model.K))
    lower_bounds!(opt, 1e-10)
    upper_bounds!(opt, 100.0)
    xtol_rel!(opt, 1e-4)
    xtol_abs!(opt, 1e-4)

    Ndivζ = calculate_Ndivζ(model, d)

    max_objective!(
        opt,
        (ν, ∇ν) -> ν_objective(ν, ∇ν, model.λ[d], Ndivζ, model.μ, model.invΣ)
    )
    (optobj, optν, ret) = optimize(opt, model.ν[d])
    model.ν[d] .= optν
end

function update_ζ!(model::IMMCTM, d::Int)
    start = 1
    for m in 1:model.M
        stop = start + model.K[m] - 1
        model.ζ[d][m] = sum(
            exp(model.λ[d][start:stop] .+ 0.5 * model.ν[d][start:stop])
        )
        start += model.K[m]
    end
end

# TODO
function update_θ!(model::IMMCTM, d::Int)
    for m in 1:model.M
        for w in 1:size(model.X[d][m])[1]
            v = model.X[d][m][w, 1]

            offset = 0
            for k in 1:model.K[m]
                model.θ[d][m][k, w] = exp(model.λ[d][offset + k])

                for i in 1:model.I[m]
                    model.θ[d][m][k, w] *= exp(
                        model.Elnϕ[m][k][i][model.features[m][v, i]]
                    )
                end
            end
            offset += model.K[m]

            model.θ[d][m][:, w] ./= sum(model.θ[d][m][:, w])
        end
    end
end

function update_μ!(model::IMMCTM)
    model.μ .= mean(model.λ)
end

function update_Σ!(model::IMMCTM)
    model.Σ .= sum(diagm.(model.ν))
    for d in 1:model.D
        diff = model.λ[d] .- model.μ
        model.Σ .+= diff * diff'
    end
    model.Σ ./= model.D
    model.invΣ .= inv(model.Σ)
end

# TODO
function update_Elnϕ!(model::IMMCTM)
    for m in 1:model.M
        for k in 1:model.K[m]
            for i in 1:model.I[m]
                model.Elnϕ[m][k][i] .= digamma(model.γ[m][k][i]) .-
                    digamma(sum(model.γ[m][k][i]))
            end
        end
    end
end

# TODO
function update_γ!(model::IMMCTM)
    for m in 1:model.M
        for k in 1:model.K[m]
            for i in 1:model.I[m]
                for j in 1:model.J[m][i]
                    model.γ[m][k][i][j] = model.α[m] 
                end
            end
        end
    end
    for d in 1:model.D
        for m in 1:model.M
            Nθ = model.θ[d][m] .* model.X[d][m][:, 2]'
            for w in 1:size(model.X[d][m])[1]
                v = model.X[d][m][w, 1]
                for k in 1:model.K[m]
                    for i in 1:model.I[m]
                        model.γ[m][k][i][model.features[m][v, i]] += Nθ[k, w]
                    end
                end
            end
        end
    end
    update_Elnϕ!(model)
end

function svi_update_μ!(model::IMMCTM, docs::Vector{Int}, ρ::Float64)
    model.μ .= (1 - ρ) * model.μ + ρ * mean(model.λ[docs])
end

function svi_update_Σ!(model::IMMCTM, docs::Vector{Int}, ρ::Float64)
    Σ = sum(diagm.(model.ν[docs]))
    for d in docs
        diff = model.λ[d] .- model.μ
        Σ .+= diff * diff'
    end
    Σ ./= length(docs)

    model.Σ .= (1 - ρ) * model.Σ + ρ * Σ
    model.invΣ .= inv(model.Σ)
end

# TODO
function svi_update_γ!(model::IMMCTM, docs::Vector{Int}, ρ::Float64)
    γ = [
        [
            [
                fill(model.α[m], model.J[m][i]) for i in 1:model.I[m]
            ] for k in 1:model.K[m]
        ] for m in 1:model.M
    ]
    for d in docs
        for m in 1:model.M
            Nθ = model.θ[d][m] .* model.X[d][m][:, 2]'
            for w in 1:size(model.X[d][m])[1]
                v = model.X[d][m][w, 1]
                for k in 1:model.K[m]
                    for i in 1:model.I[m]
                        γ[m][k][i][model.features[m][v, i]] += Nθ[k, w]
                    end
                end
            end
        end
    end
    for m in 1:model.M
        for k in 1:model.K[m]
            for i in 1:model.I[m]
                for j in 1:model.J[m][i]
                    model.γ[m][k][i] .= (1 - ρ) * model.γ[m][k][i] .+
                        ρ * model.D / length(docs) * γ[m][k][i]
                end
            end
        end
    end

    update_Elnϕ!(model)
end

function logmvbeta(vals)
    r = 0.0
    for v in vals
        r += lgamma(v)
    end
    r -= lgamma(sum(vals))

    return r
end

# TODO
function calculate_ElnPϕ(model::IMMCTM)
    lnp = 0.0

    for m in 1:model.M
        for k in 1:model.K[m]
            for i in 1:model.I[m]
                lnp -= logmvbeta(fill(model.α[m], model.J[m][i]))
                for j in 1:model.J[m][i]
                    lnp += (model.α[m] - 1) * model.Elnϕ[m][k][i][j]
                end
            end
        end
    end

    return lnp
end

function calculate_ElnPη(model::IMMCTM)
    lnp = 0.0

    for d in 1:model.D
        diff = model.λ[d] .- model.μ
        lnp += 0.5 * (
            logdet(model.invΣ) -
            sum(model.K) * log(2π) -
            trace(diagm(model.ν[d]) * model.invΣ) -
            (diff' * model.invΣ * diff)[1]
        )
    end

    return lnp
end

function calculate_ElnPZ(model::IMMCTM)
    lnp = 0.0

    for d in 1:model.D
        Eeη = exp(model.λ[d] .+ 0.5model.ν[d])
        sumθ = calculate_sumθ(model, d)
        Ndivζ = calculate_Ndivζ(model, d)

        lnp += sum(model.λ[d] .* sumθ)
        lnp -= sum(Ndivζ .* Eeη) - sum(model.N[d])
        lnp -= sum(model.N[d] .* log(model.ζ[d]))
    end

    return lnp
end

# TODO
function calculate_ElnPX(model::IMMCTM)
    lnp = 0.0

    for d in 1:model.D
        for m in 1:model.M
            for w in 1:size(model.X[d][m])[1]
                v = model.X[d][m][w, 1]
                for i in 1:model.I[m]
                    for k in 1:model.K[m]
                        lnp += model.X[d][m][w, 2] * model.θ[d][m][k, w] *
                            model.Elnϕ[m][k][i][model.features[m][v, i]]
                    end
                end
            end
        end
    end

    return lnp
end

# TODO
function calculate_ElnQϕ(model::IMMCTM)
    lnq = 0.0

    for m in 1:model.M
        for k in 1:model.K[m]
            for i in 1:model.I[m]
                lnq += -logmvbeta(model.γ[m][k][i])
                for j in 1:model.J[m][i]
                    lnq += (model.γ[m][k][i][j] - 1) * model.Elnϕ[m][k][i][j]
                end
            end
        end
    end
    return lnq
end

function calculate_ElnQη(model::IMMCTM)
    lnq = 0.0
    for d in 1:model.D
        lnq += -0.5 * (sum(log(model.ν[d])) + sum(model.K) * (log(2π) + 1))
    end
    return lnq
end

function calculate_ElnQZ(model::IMMCTM)
    lnq = 0.0
    for d in 1:model.D
        for m in 1:model.M
            lnq += sum(model.X[d][m][:, 2]' .* log(model.θ[d][m] .^ model.θ[d][m]))
        end
    end
    return lnq
end

function calculate_elbo(model::IMMCTM)
    elbo = 0.0
    elbo += calculate_ElnPϕ(model)
    elbo += calculate_ElnPη(model)
    elbo += calculate_ElnPZ(model)
    elbo += calculate_ElnPX(model)
    elbo -= calculate_ElnQϕ(model)
    elbo -= calculate_ElnQη(model)
    elbo -= calculate_ElnQZ(model)
    return elbo
end

# TODO
function calculate_docmodality_loglikelihood(X::Matrix{Int},
        η::Vector{Float64}, ϕ::Vector{Vector{Vector{Float64}}},
        features::Matrix{Int})
    props = exp(η) ./ sum(exp(η))

    K = length(η[1])
    I = size(features)[2]

    ll = 0.0
    for w in 1:size(X)[1]
        v = X[w, 1]
        pw = 0.0
        for k in 1:K
            tmp = props[k]
            for i in 1:I
                tmp *= ϕ[k][i][features[v, i]]
            end
            pw += tmp
        end
        ll += X[w, 2] * log(pw)
    end

    return ll / sum(X[:, 2])
end

function calculate_modality_loglikelihood(X::Vector{Matrix{Int}},
        η::Vector{Vector{Float64}}, ϕ::Vector{Vector{Vector{Float64}}},
        features::Matrix{Int})
    D = length(X)

    ll = 0.0
    N = 0
    for d in 1:D
        doc_N = sum(X[d][:, 2])
        if doc_N > 0
            doc_ll = calculate_docmodality_loglikelihood(
                X[d], η[d], ϕ, features
            )
            ll += doc_ll * doc_N
            N += doc_N
        end
    end

    return ll / N
end

# TODO
function calculate_loglikelihoods(X::Vector{Vector{Matrix{Int}}},
        model::IMMCTM)
    ll = Array(Float64, model.M)

    offset = 1
    for m in 1:model.M
        mk = offset:(offset + model.K[m] - 1)
        η = [model.λ[d][mk] for d in 1:model.D]
        Xm = [X[d][m] for d in 1:model.D]
        ϕ = [
            [model.γ[m][k][i] ./ sum(model.γ[m][k][i]) for i in 1:model.I[m]]
            for k in 1:model.K[m]
        ]

        ll[m] = calculate_modality_loglikelihood(Xm, η, ϕ, model.features[m])

        offset += model.K[m]
    end

    return ll
end

function check_convergence(metric::Vector{Vector{Float64}}; tol=1e-4)
    return maximum(abs(metric[end - 1] .- metric[end]) ./ metric[end]) < tol
end

function fitdoc!(model::IMMCTM, d::Int)
    update_ζ!(model, d)
    update_θ!(model, d)
    update_ν!(model, d)
    update_λ!(model, d)
    #TODO
    #=ll = Vector{Float64}[]=#

    #=myiter = 0=#
    #=for iter in 1:20=#
        #=update_ζ!(model, d)=#
        #=update_θ!(model, d)=#
        #=update_ν!(model, d)=#
        #=update_λ!(model, d)=#

        #=offset = 1=#
        #=iterll = Array(Float64, 2)=#
        #=for m in 1:model.M=#
            #=mk = offset:(offset + model.K[m] - 1)=#
            #=iterll[m] = calculate_document(=#
                #=[model.X[d][m]], [model.λ[d][mk]], model.γ[m], model.features[m]=#
            #=)=#
            #=offset += model.K[m]=#
        #=end=#
        #=push!(perps, iterperps)=#
        
        #=myiter = iter=#
        #=if length(perps) > 1 && check_convergence(perps, tol=1e-3)=#
            #=break=#
        #=end=#
    #=end=#
end

function fit!(model::IMMCTM; maxiter=100, verbose=true)
    ll = Vector{Float64}[]
    elbos = Float64[]

    for iter in 1:maxiter
        for d in 1:model.D
            fitdoc!(model, d)
        end

        update_μ!(model)
        update_Σ!(model)
        update_γ!(model)

        push!(ll, calculate_loglikelihoods(model.X, model))
        push!(elbos, calculate_elbo(model))

        if verbose
            println("$iter\tLog-likelihoods: ", join(ll[end], ", "))
        end

        if length(ll) > 10 && check_convergence(ll)
            model.converged = true
            break
        end
    end
    model.elbo = calculate_elbo(model)
    model.ll = ll[end]

    return ll, elbos
end

function svi!(model::IMMCTM; epochs=100, batchsize=25, verbose=true)
    ll = Vector{Float64}[]
    elbos = Float64[]

    batches = Int(ceil(model.D / batchsize))
    for epoch in 1:epochs
        docs = shuffle(1:model.D)
        batchstart = 1
        batchstop = batchsize

        for iter in 1:batches
            batch = docs[batchstart:batchstop]
            for d in batch
                fitdoc!(model, d)
            end
            batchstart = batchstop + 1
            batchstop += batchsize
            batchstop = min(batchstop, model.D)

            ρ = Float64((epoch - 1) * batches + iter + 1) ^ (-1)

            svi_update_μ!(model, batch, ρ)
            svi_update_Σ!(model, batch, ρ)
            svi_update_γ!(model, batch, ρ)
        end

        push!(ll, calculate_loglikelihoods(model.X, model))
        push!(elbos, calculate_elbo(model))

        if verbose
            println("$epoch\tLog-likelihoods: ", join(ll[end], ", "))
        end
        if length(ll) > 10 && check_convergence(ll, tol=1e-5)
            model.converged = true
            break
        end

    end

    return ll, elbos
end

# TODO
function metafit(ks::Vector{Int}, α::Vector{Float64},
        features::Vector{Matrix{Int}},
        X::Vector{Vector{Matrix{Int}}}; restarts::Int=25)
    
    M = length(ks)
    nvals = Int[sum(maximum(features[m], 1)) for m in 1:M]
    γs = Matrix{Float64}[
        Array(Float64, nvals[m], restarts * ks[m]) for m in 1:M
    ]

    for r in 1:restarts
        println("restart $r")
        model = IMMCTM(ks, α, features, X)
        fit!(model, maxiter=1000, verbose=false)

        for m in 1:M
            for k in ks[m]
                γs[m][:, r + k - 1] .= log(vcat(model.γ[m][k]...))
            end
        end
    end

    best_cost = fill(Inf, M)
    best_centres = [Array(Float64, nvals[m], ks[m]) for m in 1:M]
    res = [kmeans(γs[m], ks[m]) for m in 1:M]
    for m in 1:M
        for _ in 1:10
            res = kmeans(γs[m], ks[m])
            if res.totalcost < best_cost[m]
                best_cost[m] = res.totalcost
                best_centres[m] .= res.centers
            end
        end
    end

    model = IMMCTM(ks, α, features, X)
    for m in 1:model.M
        for k in 1:ks[m]
            centre = vec(exp(best_centres[m][:, k]))

            start = 1
            for i in 1:model.I[m]
                stop = start + model.J[m][i] - 1
                model.γ[m][k][i] .= centre[start:stop]
                start = stop + 1
            end
        end
    end

    fit!(model, maxiter=500, verbose=false)
    return model
end

# TODO
function fit_heldout(Xheldout::Vector{Vector{Matrix{Int}}}, model::IMMCTM;
        maxiter=100, verbose=false)

    heldout_model = IMMCTM(model.K, model.α, model.features, Xheldout)
    heldout_model.μ .= model.μ
    heldout_model.Σ .= model.Σ
    heldout_model.invΣ .= model.invΣ
    heldout_model.γ .= model.γ
    heldout_model.Elnϕ .= model.Elnϕ

    ll = Vector{Float64}[]
    for iter in 1:maxiter
        for d in 1:heldout_model.D
            fitdoc!(heldout_model, d)
        end

        push!(ll, calculate_loglikelihoods(Xheldout, heldout_model))

        if verbose
            println("$iter\tLog-likelihoods: ", join(ll[end], ", "))
        end

        if length(ll) > 10 && check_convergence(ll)
            heldout_model.converged = true
            break
        end
    end

    return heldout_model
end

# TODO
function predict_modality_η(Xobs::Vector{Vector{Matrix{Int}}}, m::Int,
        model::IMMCTM; maxiter=100, verbose=false)
    obsM = setdiff(1:model.M, m)

    moffset = sum(model.K[1:(m - 1)])
    unobsMK = (moffset + 1):(moffset + model.K[m])
    obsMK = setdiff(1:sum(model.K), unobsMK)

    obsmodel = IMMCTM(model.K[obsM], model.α[obsM], model.features[obsM], Xobs)
    obsmodel.μ .= model.μ[obsMK]
    obsmodel.Σ .= model.Σ[obsMK, obsMK]
    obsmodel.invΣ .= model.invΣ[obsMK, obsMK]
    obsmodel.γ .= model.γ[obsM]

    ll = Vector{Float64}[]
    for iter in 1:maxiter
        for d in 1:obsmodel.D
            fitdoc!(obsmodel, d)
        end

        push!(ll, calculate_loglikelihoods(Xobs, obsmodel))

        if verbose
            println("$iter\tLog-likelihoods: ", join(ll[end], ", "))
        end

        if length(ll) > 10 && check_convergence(ll)
            obsmodel.converged = true
            break
        end
    end

    if !obsmodel.converged
        warn("model not converged.")
    end

    η = [
        (
            model.μ[unobsMK] .+ model.Σ[unobsMK, obsMK] *
            model.invΣ[obsMK, obsMK] * (obsmodel.λ[d] .- model.μ[obsMK])
        )
        for d in 1:obsmodel.D
    ]

    return η
end