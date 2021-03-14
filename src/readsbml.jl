
const VPtr = Ptr{Cvoid}

"""
    function readSBML(fn::String)::Model

Read the SBML from a XML file in `fn` and return the contained `Model`.
"""
function readSBML(fn::String)::Model
    doc = ccall(sbml(:readSBML), VPtr, (Cstring,), fn)
    try
        n_errs = ccall(sbml(:SBMLDocument_getNumErrors), Cuint, (VPtr,), doc)
        for i = 0:n_errs-1
            err = ccall(sbml(:SBMLDocument_getError), VPtr, (VPtr, Cuint), doc, i)
            msg = unsafe_string(ccall(sbml(:XMLError_getMessage), Cstring, (VPtr,), err))
            @warn "SBML reported error: $msg"
        end
        if n_errs > 0
            throw(AssertionError("Opening SBML document has reported errors"))
        end

        if 0 == ccall(sbml(:SBMLDocument_isSetModel), Cint, (VPtr,), doc)
            throw(AssertionError("SBML document contains no model"))
        end

        model = ccall(sbml(:SBMLDocument_getModel), VPtr, (VPtr,), doc)

        return extractModel(model)
    finally
        ccall(sbml(:SBMLDocument_free), Nothing, (VPtr,), doc)
    end
end

function extractModel(mdl::VPtr)::Model
    parameters = Dict{String,Float64}()
    for i = 1:ccall(sbml(:Model_getNumParameters), Cuint, (VPtr,), mdl)
        p = ccall(sbml(:Model_getParameter), VPtr, (VPtr, Cuint), mdl, i - 1)
        id = unsafe_string(ccall(sbml(:Parameter_getId), Cstring, (VPtr,), p))
        v = ccall(sbml(:Parameter_getValue), Cdouble, (VPtr,), p)
        parameters[id] = v
    end

    units = Dict{String,Vector{UnitPart}}()
    for i = 1:ccall(sbml(:Model_getNumUnitDefinitions), Cuint, (VPtr,), mdl)
        ud = ccall(sbml(:Model_getUnitDefinition), VPtr, (VPtr, Cuint), mdl, i - 1)
        id = unsafe_string(ccall(sbml(:UnitDefinition_getId), Cstring, (VPtr,), ud))
        units[id] = [
            begin
                u = ccall(sbml(:UnitDefinition_getUnit), VPtr, (VPtr, Cuint), ud, j - 1)
                UnitPart(
                    unsafe_string(
                        ccall(
                            sbml(:UnitKind_toString),
                            Cstring,
                            (Cint,),
                            ccall(sbml(:Unit_getKind), Cint, (VPtr,), u),
                        ),
                    ),
                    ccall(sbml(:Unit_getExponent), Cint, (VPtr,), u),
                    ccall(sbml(:Unit_getScale), Cint, (VPtr,), u),
                    ccall(sbml(:Unit_getMultiplier), Cdouble, (VPtr,), u),
                )
            end for j = 1:ccall(sbml(:UnitDefinition_getNumUnits), Cuint, (VPtr,), ud)
        ]
    end

    compartments = [
        unsafe_string(
            ccall(
                sbml(:Compartment_getId),
                Cstring,
                (VPtr,),
                ccall(sbml(:Model_getCompartment), VPtr, (VPtr, Cuint), mdl, i - 1),
            ),
        ) for i = 1:ccall(sbml(:Model_getNumCompartments), Cuint, (VPtr,), mdl)
    ]

    species = Dict{String,Species}()
    for i = 1:ccall(sbml(:Model_getNumSpecies), Cuint, (VPtr,), mdl)
        sp = ccall(sbml(:Model_getSpecies), VPtr, (VPtr, Cuint), mdl, i - 1)
        species[unsafe_string(ccall(sbml(:Species_getId), Cstring, (VPtr,), sp))] = Species(
            unsafe_string(ccall(sbml(:Species_getName), Cstring, (VPtr,), sp)),
            unsafe_string(ccall(sbml(:Species_getCompartment), Cstring, (VPtr,), sp)),
        )
    end

    reactions = Dict{String,Reaction}()

    for i = 1:ccall(sbml(:Model_getNumReactions), Cuint, (VPtr,), mdl)
        re = ccall(sbml(:Model_getReaction), VPtr, (VPtr, Cuint), mdl, i - 1)
        lb = (-Inf, "")
        ub = (Inf, "")
        oc = 0.0

        kl = ccall(sbml(:Reaction_getKineticLaw), VPtr, (VPtr,), re)
        if kl != C_NULL
            for j = 1:ccall(sbml(:KineticLaw_getNumParameters), Cuint, (VPtr,), kl)
                p = ccall(sbml(:KineticLaw_getParameter), VPtr, (VPtr, Cuint), kl, j - 1)
                id = unsafe_string(ccall(sbml(:Parameter_getId), Cstring, (VPtr,), p))
                pval = () -> ccall(sbml(:Parameter_getValue), Cdouble, (VPtr,), p)
                punit =
                    () ->
                        unsafe_string(ccall(sbml(:Parameter_getUnits), Cstring, (VPtr,), p))
                if id == "LOWER_BOUND"
                    lb = (pval(), punit())
                elseif id == "UPPER_BOUND"
                    ub = (pval(), punit())
                elseif id == "OBJECTIVE_COEFFICIENT"
                    oc = pval()
                end
            end
        end

        # TRICKY: SBML spec is completely silent about the situation when
        # someone specifies both the above and below formats of the flux bounds
        # for one reaction. Notably, these do not really specify much
        # interaction with units. In this case, we'll just set a special
        # "[fbc]" unit that has no specification in `units`, and hope the users
        # can make something out of it.
        re_fbc = ccall(sbml(:SBase_getPlugin), VPtr, (VPtr, Cstring), re, "fbc")
        if re_fbc != C_NULL
            fbcb =
                ccall(sbml(:FbcReactionPlugin_getLowerFluxBound), Cstring, (VPtr,), re_fbc)
            if fbcb != C_NULL && haskey(parameters, unsafe_string(fbcb))
                lb = (parameters[unsafe_string(fbcb)], "[fbc]")
            end
            fbcb =
                ccall(sbml(:FbcReactionPlugin_getUpperFluxBound), Cstring, (VPtr,), re_fbc)
            if fbcb != C_NULL && haskey(parameters, unsafe_string(fbcb))
                ub = (parameters[unsafe_string(fbcb)], "[fbc]")
            end
        end

        stoi = Dict{String,Float64}()
        add_stoi =
            (sr, factor) ->
                stoi[unsafe_string(
                    ccall(sbml(:SpeciesReference_getSpecies), Cstring, (VPtr,), sr),
                )] =
                    ccall(sbml(:SpeciesReference_getStoichiometry), Cdouble, (VPtr,), sr) *
                    factor

        for j = 1:ccall(sbml(:Reaction_getNumReactants), Cuint, (VPtr,), re)
            sr = ccall(sbml(:Reaction_getReactant), VPtr, (VPtr, Cuint), re, j - 1)
            add_stoi(sr, -1)
        end

        for j = 1:ccall(sbml(:Reaction_getNumProducts), Cuint, (VPtr,), re)
            sr = ccall(sbml(:Reaction_getProduct), VPtr, (VPtr, Cuint), re, j - 1)
            add_stoi(sr, 1)
        end

        reactions[unsafe_string(ccall(sbml(:Reaction_getId), Cstring, (VPtr,), re))] =
            Reaction(stoi, lb, ub, oc)
    end

    return Model(parameters, units, compartments, species, reactions)
end
