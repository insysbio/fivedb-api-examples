using Pkg
# List of packages to check/install
packages = ["HTTP", "JSON3", "DataFrames", "Dates", "StatsPlots", "Serialization"]
# Check if each package is installed, and install it if not
for pkg in packages
    if !(pkg in keys(Pkg.project().dependencies))
        println("Package '$pkg' is not installed. Installing now...")
        Pkg.add(pkg)
    else
        println("Package '$pkg' is already installed.")
    end
end
using HTTP
using JSON3
using DataFrames
using Dates
using Serialization
# Defining a structure for storing the result of an API request
struct APICallResult
    content::String
    response::Any
end
# Defining the structure for storing the token
struct BearerRequestToken
    token::String
    expires_in::DateTime
    response::Any
end
# An abstract type for database management
abstract type AbstractDBManager end
# A specific type for database management
mutable struct DBManagerBase <: AbstractDBManager
    url::String
    system_type::String
    path_to_credentials::String
    token::Union{Nothing, BearerRequestToken}
    headers_df::DataFrame
    function DBManagerBase(url::String, system_type::String, path_to_credentials::String, token::Union{Nothing, BearerRequestToken}=nothing)
        new(url, system_type, path_to_credentials, token, DataFrame())
    end
end
# Method for requesting an authentication token
function requestAuthToken(db::DBManagerBase)
    println("Requesting authentication token...")
    temp_path = tempdir()
    system_type = db.system_type
    token_file_path = joinpath(temp_path, "token_cache_$(system_type).jls")
    if isfile(token_file_path)
        cached_token = Serialization.deserialize(token_file_path)  # Using Serialization.deserialize
        if cached_token.expires_in > now()
            println("Using cached token.")
            db.token = cached_token
            return db.token
        end
    end
    credentials = readlines(db.path_to_credentials)
    credentials_data = split(credentials[1], " ")
    username = credentials_data[1]
    password = credentials_data[2]
    db.token = nothing
    body = Dict(
        "grant_type" => "password",
        "client_id" => username,
        "client_secret" => password,
        "password" => password,
        "username" => username
    )
    post_token_response = HTTP.post(
        db.url * "/oauth/token",
        body=body,
        headers=Dict("Content-Type" => "application/x-www-form-urlencoded")
    )
    if post_token_response.status == 200
        println("Authentication token received successfully.")
        post_token_response_content = JSON3.read(post_token_response.body)
        if !haskey(post_token_response_content, :access_token)
            error("Access token is missing in the API response.")
        end
        if !haskey(post_token_response_content, :expires_in)
            error("Expires_in is missing in the API response.")
        end
        token_expire_time = now() + Second(post_token_response_content.expires_in)
        db.token = BearerRequestToken(
            post_token_response_content.access_token,
            token_expire_time,
            post_token_response
        )
        Serialization.serialize(token_file_path, db.token)  # Using Serialization.serialize
        println("Token saved to disk.")
    else
        @warn "Failed to receive authentication token. Status code: $(post_token_response.status)"
        db.token = BearerRequestToken("", now(), post_token_response)
    end
    return db.token
end
# Method for verifying authentication
function isAuthenticated(db::DBManagerBase)
    if db.token !== nothing && db.token.token != ""
        println("User is authenticated.")
        return true
    end
    println("User is not authenticated.")
    return false
end
# Method for executing an API request
function doAPICall(db::DBManagerBase, url::String, params::Dict=Dict())
    println("Making API call to: $(db.url * url)")
    if !isAuthenticated(db)
        println("User is not authenticated. Requesting token...")
        requestToken = requestAuthToken(db)
        if requestToken.token == ""
            error("User is not authenticated. Token request failed...")
        end
    end
    post_apicall_response = HTTP.get(
        db.url * url,
        query=params,
        headers=Dict("Authorization" => "Bearer $(db.token.token)")
    )
    response_content = String(post_apicall_response.body)
    if isempty(response_content)
        @warn "Empty response content from API."
        response_content = ""
    end
    return APICallResult(response_content, post_apicall_response)
end
# Method for getting a dictionary
function getDictionary(db::DBManagerBase, url::String, dictionary_name::String, force::Bool=false)
    temp_path = tempdir()
    system_type = db.system_type
    cache_file_path = joinpath(temp_path, "$(dictionary_name)_$(system_type).jls")
    if isfile(cache_file_path) && !force
        println("Loading dictionary from cache...")
        return Serialization.deserialize(cache_file_path)
    end
    println("Fetching dictionary data...")
    apiCallResult = doAPICall(db, url, Dict())
    if apiCallResult.response.status == 200
        println("Dictionary data fetched successfully.")
        content = apiCallResult.content
        if !isempty(content)
            # Parse JSON response
            json_data = JSON3.read(content)
            # Checking if the response is an array
            if json_data isa AbstractArray
                # Extracting the "Name" field (or another field) from each element of the array
        dictionary_data = [item.Name for item in json_data] 
            else
                @warn "Unexpected JSON structure. Expected an array."
                return nothing
            end
            Serialization.serialize(cache_file_path, dictionary_data)
            println("Dictionary saved to cache at: $cache_file_path")
            return dictionary_data
        else
            @warn "Empty response from API."
            return nothing
        end
    else
        @warn "Failed to fetch dictionary data. Status code: $(apiCallResult.response.status)"
        return nothing
    end
end
# Method for selecting elements
function selectElements(user_elements, db_elements, caption)
    missing = setdiff(user_elements, db_elements)
    if !isempty(missing)
        error("Error: next $caption didn't found: $(join(missing, ", ")) in database.")
    end
    return user_elements[.!isnothing.(user_elements)]
end
# Specific type for managing the Cytocon database
mutable struct CytoconDBManager
    db::DBManagerBase
    diseases::Vector{String}
    tissues_types::Vector{String}
    species::Vector{String}
    markers::Vector{String}
    disease_attributes::Vector{String}
    patient_group_attributes::Vector{String}
    function CytoconDBManager(url::String, path_to_credentials::String)
        db = DBManagerBase(url, "cytocon", path_to_credentials)
        new(db, [], [], [], [], [], [])
    end
end
# Method for loading dictionaries
function loadDictionaries(db::CytoconDBManager, force::Bool=false)
    db.diseases = getDictionary(db.db, "/api/v1/diseases", "diseases", force)
    db.tissues_types = getDictionary(db.db, "/api/v1/tissues_types", "tissues_types", force)
    db.species = getDictionary(db.db, "/api/v1/species", "species", force)
    db.markers = getDictionary(db.db, "/api/v1/markers", "markers", force)
    db.disease_attributes = getDictionary(db.db, "/api/v1/disease_attributes", "disease_attributes", force)
    db.patient_group_attributes = getDictionary(db.db, "/api/v1/patient_group_attributes", "patient_group_attributes", force)
end
# Method for saving a dictionary to a text file
function saveDictionaryToTextFile(dictionary, file_path::String, caption::String)
    write(file_path, join(dictionary, "\n"))
    println("Dictionary '$caption' successfully saved to text file: $file_path")
end
# Method for checking a dictionary
function checkDictionary(db::CytoconDBManager, dictionary, caption::String)
    if isnothing(dictionary) || isempty(dictionary)
        println("Dictionary $caption is empty. Loading dictionaries...")
        loadDictionaries(db)
    end
end
# Method for selecting diseases
function selectDiseases(db::CytoconDBManager, diseases)
    checkDictionary(db, db.diseases, "diseases")
    return selectElements(diseases, db.diseases, "diseases")
end
# Method for selecting tissue types
function selectTissuesTypes(db::CytoconDBManager, tissues_types)
    checkDictionary(db, db.tissues_types, "tissues types")
    return selectElements(tissues_types, db.tissues_types, "tissues types")
end
# Method for selecting species
function selectSpecies(db::CytoconDBManager, species)
    checkDictionary(db, db.species, "species")
    return selectElements(species, db.species, "species")
end
# Method for selecting markers
function selectMarkers(db::CytoconDBManager, markers)
    checkDictionary(db, db.markers, "markers")
    return selectElements(markers, db.markers, "markers")
end
# Method for saving diseases to a file
function saveDiseases(db::CytoconDBManager, file_path::String)
    checkDictionary(db, db.diseases, "diseases")
    saveDictionaryToTextFile(db.diseases, file_path, "diseases")
end
# Method for saving tissue types to a file
function saveTissuesTypes(db::CytoconDBManager, file_path::String)
    checkDictionary(db, db.tissues_types, "tissues types")
    saveDictionaryToTextFile(db.tissues_types, file_path, "tissues types")
end
# Method for saving species to a file
function saveSpecies(db::CytoconDBManager, file_path::String)
    checkDictionary(db, db.species, "species")
    saveDictionaryToTextFile(db.species, file_path, "species")
end
# Method for saving markers to a file
function saveMarkers(db::CytoconDBManager, file_path::String)
    checkDictionary(db, db.markers, "markers")
    saveDictionaryToTextFile(db.markers, file_path, "markers")
end
# Method for saving headers to a file
function saveHeaders(db::CytoconDBManager, file_path::String)
    if isempty(db.db.headers_df)
        error("headers_df is empty. No data to save.")
    end
    if !in("ColumnDesc", names(db.db.headers_df))
        error("Column 'ColumnDesc' not found in headers_df.")
    end
    variable_desc = db.db.headers_df.ColumnDesc
    write(file_path, join(variable_desc, "\n"))
    println("Column 'ColumnDesc' successfully saved to file: $file_path")
end
# Method for querying data
function queryData(db::CytoconDBManager, species, tissue_types, diseases, markers, headers, wstat_switch::String="false")
    params = Dict(
        "tissue_types" => join(tissue_types, ","),
        "diseases" => join(diseases, ","),
        "species" => join(species, ","),
        "markers" => join(markers, ","),
        "headers" => join(headers, ","),
        "wstatSwitch" => wstat_switch
    )
    apiCallResult = doAPICall(db.db, "/api/v1/query_data", params)
    if apiCallResult.response.status == 200
        println("Query data fetched successfully.")
        if !isempty(apiCallResult.content)
            # Converting JSON response to DataFrame
            json_data = JSON3.read(apiCallResult.content)
            if json_data isa AbstractArray
                # Converting each JSON object to a dictionary with String keys
                complete_json_data = map(json_obj -> begin
                    # Creating a new dictionary with String keys
                    new_obj = Dict{String, Any}()
                    for (key, value) in json_obj
                        new_obj[string(key)] = value
                    end
                    # Adding missing keys with value missing
                    for key in headers
                        if !haskey(new_obj, key)
                            new_obj[key] = missing
                        end
                    end
                    new_obj
                end, json_data)
                # Converting array of dictionaries to DataFrame
                df = DataFrame(complete_json_data)
                return df
            else
                @warn "Incorrect JSON response structure. Expected array of objects."
                return nothing
            end
        else
            @warn "Empty response from API."
            return nothing
        end
    else
        @warn "Failed to fetch query data."
        return nothing
    end
end
# Method for querying headers
function queryHeaders(db::CytoconDBManager, diseases::String, force::Bool=false)
    cache_dir = tempdir()
    cache_file = joinpath(cache_dir, "query_headers_$diseases.jls")
    if !force && isfile(cache_file)
        println("Loading data from cache...")
        db.db.headers_df = Serialization.deserialize(cache_file)
        return db.db.headers_df
    end
    println("Executing API request...")
    params = Dict("diseases" => diseases)
    apiCallResult = doAPICall(db.db, "/api/v1/query_data_headers", params)
    if apiCallResult.response.status == 200
        response_content = apiCallResult.content
        if isempty(response_content)
            @warn "Empty server response."
            return nothing
        end
        try
            # Reading JSON response
            json_data = JSON3.read(response_content)
            # Converting array of objects to DataFrame
            if json_data isa AbstractArray
                db.db.headers_df = DataFrame(
                    ColumnVariable = [item.ColumnVariable for item in json_data],
                    ColumnDesc = [item.ColumnDesc for item in json_data]
                )
            else
                @warn "Incorrect JSON response structure. Expected array of objects."
                return nothing
            end
            # Saving data to cache
            Serialization.serialize(cache_file, db.db.headers_df)
            println("Data saved to cache: $cache_file")
            return db.db.headers_df
        catch e
            @warn "Error processing JSON: $e"
            return nothing
        end
    else
        @warn "Error fetching data. Status code: $(apiCallResult.response.status)"
        return nothing
    end
end
# Method for selecting headers
function SelectHeader(db::CytoconDBManager, column_descriptions)
    if isempty(db.db.headers_df)
        error("Headers not loaded. Use the queryHeaders method to load data.")
    end
    selected_variables = [db.db.headers_df.ColumnVariable[db.db.headers_df.ColumnDesc .== desc][1] for desc in column_descriptions]
    return selected_variables
end
# FIVEDBManager class inheriting from DBManagerBase
mutable struct FIVEDBManager
    db::DBManagerBase
    process_types::Vector{String}
    parameters::Vector{String}
    cell_types::Vector{String}
    stimulateds::Vector{String}
    patient_states::Vector{String}
    products::Vector{String}
    daughter_cells::Vector{String}
    regulators::Vector{String}
    modifiers::Vector{String}
    function FIVEDBManager(url::String, path_to_credentials::String)
        db = DBManagerBase(url, "fivedb1", path_to_credentials)
        new(db, [], [], [], [], [], [], [], [], [])
    end
end
# Methods for FIVEDBManager
function getProcessTypes(db::FIVEDBManager, force::Bool=false)
    return getDictionary(db.db, "/api/v1/process_types", "process_types", force)
end
function getParameters(db::FIVEDBManager, force::Bool=false)
    return getDictionary(db.db, "/api/v1/parameters", "parameters", force)
end
function getCellTypes(db::FIVEDBManager, force::Bool=false)
    return getDictionary(db.db, "/api/v1/cell_types", "cell_types", force)
end
function getStimulated(db::FIVEDBManager, force::Bool=false)
    return getDictionary(db.db, "/api/v1/stimulated", "stimulated", force)
end
function getPatientStates(db::FIVEDBManager, force::Bool=false)
    return getDictionary(db.db, "/api/v1/patient_states", "patient_states", force)
end
function getProducts(db::FIVEDBManager, force::Bool=false)
    return getDictionary(db.db, "/api/v1/products", "products", force)
end
function getDaughterCells(db::FIVEDBManager, force::Bool=false)
    return getDictionary(db.db, "/api/v1/daughter_cells", "daughter_cells", force)
end
function getRegulators(db::FIVEDBManager, force::Bool=false)
    return getDictionary(db.db, "/api/v1/regulators", "regulators", force)
end
function getModifiers(db::FIVEDBManager, force::Bool=false)
    return getDictionary(db.db, "/api/v1/modifiers", "modifiers", force)
end
function loadDictionaries(db::FIVEDBManager, force::Bool=false)
    db.process_types = getProcessTypes(db, force)
    db.parameters = getParameters(db, force)
    #db.cell_types = getCellTypes(db, force)
    db.stimulateds = getStimulated(db, force)
    db.patient_states = getPatientStates(db, force)
    db.products = getProducts(db, force)
    db.daughter_cells = getDaughterCells(db, force)
    db.regulators = getRegulators(db, force)
    db.modifiers = getModifiers(db, force)
end
function saveDictionaryToTextFile(db::FIVEDBManager, dictionary::Vector{String}, file_path::String, caption::String)
    write(file_path, join(dictionary, "\n"))
    println("Dictionary '$caption' successfully saved to text file: $file_path")
end
function checkDictionary(db::FIVEDBManager, dictionary::Vector{String}, caption::String)
    if isempty(dictionary)
        println("Dictionary $caption is empty. Loading dictionaries...")
        loadDictionaries(db)
    end
end
function selectProcessTypes(db::FIVEDBManager, process_types)
    checkDictionary(db, db.process_types, "process_types")
    return selectElements(process_types, db.process_types, "process_types")
end
function selectParameters(db::FIVEDBManager, parameters)
    checkDictionary(db, db.parameters, "parameters")
    return selectElements(parameters, db.parameters, "parameters")
end
function selectCellTypes(db::FIVEDBManager, cell_types)
    checkDictionary(db, db.cell_types, "cell_types")
    return selectElements(cell_types, db.cell_types, "cell_types")
end
function selectStimulated(db::FIVEDBManager, stimulateds)
    checkDictionary(db, db.stimulateds, "stimulateds")
    return selectElements(stimulateds, db.stimulateds, "stimulateds")
end
function selectPatientStates(db::FIVEDBManager, patient_states)
    checkDictionary(db, db.patient_states, "patient_states")
    return selectElements(patient_states, db.patient_states, "patient_states")
end
function selectProducts(db::FIVEDBManager, products)
    checkDictionary(db, db.products, "products")
    return selectElements(products, db.products, "products")
end
function selectDaughterCells(db::FIVEDBManager, daughter_cells)
    checkDictionary(db, db.daughter_cells, "daughter_cells")
    return selectElements(daughter_cells, db.daughter_cells, "daughter_cells")
end
function selectRegulators(db::FIVEDBManager, regulators)
    checkDictionary(db, db.regulators, "regulators")
    return selectElements(regulators, db.regulators, "regulators")
end
function selectModifiers(db::FIVEDBManager, modifiers)
    checkDictionary(db, db.modifiers, "modifiers")
    return selectElements(modifiers, db.modifiers, "modifiers")
end
function saveProcessTypes(db::FIVEDBManager, file_path::String)
    checkDictionary(db, db.process_types, "process_types")
    saveDictionaryToTextFile(db, db.process_types, file_path, "process_types")
end
function saveParameters(db::FIVEDBManager, file_path::String)
    checkDictionary(db, db.parameters, "parameters")
    saveDictionaryToTextFile(db, db.parameters, file_path, "parameters")
end
function saveCellTypes(db::FIVEDBManager, file_path::String)
    checkDictionary(db, db.cell_types, "cell_types")
    saveDictionaryToTextFile(db, db.cell_types, file_path, "cell_types")
end
function saveStimulateds(db::FIVEDBManager, file_path::String)
    checkDictionary(db, db.stimulateds, "stimulateds")
    saveDictionaryToTextFile(db, db.stimulateds, file_path, "stimulateds")
end
function savePatientStates(db::FIVEDBManager, file_path::String)
    checkDictionary(db, db.patient_states, "patient_states")
    saveDictionaryToTextFile(db, db.patient_states, file_path, "patient_states")
end
function saveProducts(db::FIVEDBManager, file_path::String)
    checkDictionary(db, db.products, "products")
    saveDictionaryToTextFile(db, db.products, file_path, "products")
end
function saveDaughterCells(db::FIVEDBManager, file_path::String)
    checkDictionary(db, db.daughter_cells, "daughter_cells")
    saveDictionaryToTextFile(db, db.daughter_cells, file_path, "daughter_cells")
end
function saveRegulators(db::FIVEDBManager, file_path::String)
    checkDictionary(db, db.regulators, "regulators")
    saveDictionaryToTextFile(db, db.regulators, file_path, "regulators")
end
function saveModifiers(db::FIVEDBManager, file_path::String)
    checkDictionary(db, db.modifiers, "modifiers")
    saveDictionaryToTextFile(db, db.modifiers, file_path, "modifiers")
end
function queryData(db::FIVEDBManager, process_type, parameter, cell_type, stimulated, 
                   patient_state, product, daughter, regulator, 
                   modifier, headers, wstat_switch::String="false")
    params = Dict(
        "process_type" => join(process_type, ","),
        "parameter" => join(parameter, ","),
        "cell_type" => join(cell_type, ","),
        "stimulated" => join(stimulated, ","),
        "patient_state" => join(patient_state, ","),
        "product" => join(product, ","),
        "daughter" => join(daughter, ","),
        "regulator" => join(regulator, ","),
        "modifier" => join(modifier, ","),
        "headers" => join(headers, ","),
        "wstatSwitch" => wstat_switch
    )
    apiCallResult = doAPICall(db.db, "/api/v1/query_data", params)
    if apiCallResult.response.status == 200
        println("Query data fetched successfully.")
        if !isempty(apiCallResult.content)
            # Converting JSON response to DataFrame
            json_data = JSON3.read(apiCallResult.content)
            if json_data isa AbstractArray
                # Converting each JSON object to a dictionary with String keys
                complete_json_data = map(json_obj -> begin
                    # Creating a new dictionary with String keys
                    new_obj = Dict{String, Any}()
                    for (key, value) in json_obj
                        key_str = string(key)  # Converting key to string
                        new_obj[key_str] = value
                    end
                    # Adding missing keys with value missing
                    for key in headers
                        if !haskey(new_obj, key)
                            new_obj[key] = missing
                        end
                    end
                    new_obj
                end, json_data)
                # Converting array of dictionaries to DataFrame
                df = DataFrame(complete_json_data)
                return df
            else
                @warn "Incorrect JSON response structure. Expected array of objects."
                return nothing
            end
        else
            @warn "Empty response from API."
            return nothing
        end
    else
        @warn "Failed to fetch query data."
        return nothing
    end
end
function queryHeaders(db::FIVEDBManager, force::Bool=false)
    cache_dir = tempdir()
    cache_file = joinpath(cache_dir, "query_headers_5db.rds")
    if !force && isfile(cache_file)
        println("Loading data from cache...")
        db.db.headers_df = deserialize(cache_file)
        return db.db.headers_df
    end
    println("Executing API request...")
    apiCallResult = doAPICall(db.db, "/api/v1/query_data_headers")
    if apiCallResult.response.status == 200
        response_content = apiCallResult.content
        if isempty(response_content)
            @warn "Empty server response."
            return nothing
        end
        try
            # Reading JSON response
            json_data = JSON3.read(response_content)
            # Converting array of objects to DataFrame
            if json_data isa AbstractArray
                db.db.headers_df = DataFrame(
                    ColumnVariable = [item.ColumnVariable for item in json_data],
                    ColumnDesc = [item.ColumnDesc for item in json_data]
                )
            else
                @warn "Incorrect JSON response structure. Expected array of objects."
                return nothing
            end
            # Saving data to cache
            Serialization.serialize(cache_file, db.db.headers_df)
            println("Data saved to cache: $cache_file")
            return db.db.headers_df
        catch e
            @warn "Error processing JSON: $e"
            return nothing
        end
    else
        @warn "Error fetching data. Status code: $(apiCallResult.response.status)"
        return nothing
    end
end

# Method for selecting headers
function SelectHeader(db::FIVEDBManager, column_descriptions)
    if isempty(db.db.headers_df)
        error("Headers not loaded. Use the queryHeaders method to load data.")
    end

    selected_variables = [db.db.headers_df.ColumnVariable[db.db.headers_df.ColumnDesc .== desc][1] for desc in column_descriptions]
    return selected_variables
end

# Method for saving headers to a file
function saveHeaders(db::FIVEDBManager, file_path::String)
    if isempty(db.db.headers_df)
        error("headers_df is empty. No data to save.")
    end
    if !in("ColumnDesc", names(db.db.headers_df))
        error("Column 'ColumnDesc' not found in headers_df.")
    end

    variable_desc = db.db.headers_df.ColumnDesc
    write(file_path, join(variable_desc, "\n"))
    println("Column 'ColumnDesc' successfully saved to file: $file_path")
end

# Automatically export all functions defined in the module
for name in names(@__MODULE__; all=true)
    if isdefined(@__MODULE__, name) && name ∉ (Symbol(@__MODULE__), :eval, :include)
        @eval export $name
    end
end
