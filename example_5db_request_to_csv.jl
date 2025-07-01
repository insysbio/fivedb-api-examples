#=
Example of Querying the Insysbio FIVEDB Database via REST API

This Julia script performs the following operations:

1. Connecting to FIVEDB and Loading Reference Data
   - Authenticates with the FIVEDB database via REST API using provided credentials
   - Downloads metadata: lists of process types, parameters, cell types, stimulated factors,
     patient states, products, regulators, modifiers, and daughter cells
   - Saves these reference datasets as local files for future use

2. Constructing and Executing a Query
   - Selects specific process types (e.g., Migration)
   - Selects specific parameters (e.g., Emax)
   - Leaves other parameters (cell types, stimulated factors, patient states, products,
     regulators, modifiers, daughter cells) unrestricted
   - Requests specific data columns:
     * Parameter name
     * Parameter value
     * Parameter unit
     * Number of in vitro experiments

3. Saving the Results
   - Processes the data, replacing NULL values with `missing`
   - Exports results to CSV file (fivedb_query_data_jl.csv) for further analysis

Summary:
Automates data extraction from FIVEDB, enabling efficient retrieval
of structured biological data in an analysis-ready format
=#

include("insysbio_db.jl")
using Pkg

# List of packages to check/install
packages = ["StatsPlots", "PyPlot", "CSV"]

for pkg in packages
    # Check if the package is installed
    if !(pkg in keys(Pkg.installed()))
        println("Package '$pkg' is not installed. Installing now...")
        Pkg.add(pkg)
    end
end
using StatsPlots, CSV

script_dir = dirname(abspath(@__FILE__))
println("Directory of the script: ", script_dir)

path_to_dict = script_dir
path_to_fivedb_credentials = joinpath(script_dir, "fivedb_credentials.txt")
fivedb_url = "https://dev5db.insysbio.com"   

# Creating FIVEDBManager instance and loading dictionaries
println("Creating FIVEDBManager instance...")
fivedbDBManager = FIVEDBManager(
    fivedb_url,
    path_to_fivedb_credentials
)

println("Fetching species data...")
loadDictionaries(fivedbDBManager)

# Saving dictionaries to disk
saveProcessTypes(fivedbDBManager, joinpath(script_dir, "5db_process_types.jl.txt"))
saveParameters(fivedbDBManager, joinpath(script_dir, "5db_parameters.jl.txt"))
saveCellTypes(fivedbDBManager, joinpath(script_dir, "5db_cell_types.jl.txt"))
saveStimulateds(fivedbDBManager, joinpath(script_dir, "5db_stimulateds.jl.txt"))
savePatientStates(fivedbDBManager, joinpath(script_dir, "5db_patient_states.jl.txt"))
saveProducts(fivedbDBManager, joinpath(script_dir, "5db_products.jl.txt"))
saveRegulators(fivedbDBManager, joinpath(script_dir, "5db_regulators.jl.txt"))
saveModifiers(fivedbDBManager, joinpath(script_dir, "5db_modifiers.jl.txt"))
saveDaughterCells(fivedbDBManager, joinpath(script_dir, "5db_daughter_cells.jl.txt"))

# Selecting what we need to find
user_process_types = selectProcessTypes(fivedbDBManager, ["Migration"])
user_parameters = selectParameters(fivedbDBManager, ["Emax"])
user_cell_types = selectCellTypes(fivedbDBManager, [])
user_stimulateds = selectStimulated(fivedbDBManager, [])

user_patient_states = selectPatientStates(fivedbDBManager, [])
user_products = selectProducts(fivedbDBManager, [])
user_daughter_cells = selectDaughterCells(fivedbDBManager, [])
user_regulators = selectRegulators(fivedbDBManager, [])
user_modifiers = selectModifiers(fivedbDBManager, [])

# Saving column names to disk
queryHeaders(fivedbDBManager, false)
saveHeaders(fivedbDBManager, joinpath(script_dir, "5db_headers.jl.txt"))

# Selecting columns that should go into the output
selected_variables = SelectHeader(fivedbDBManager, ["Parameter", "Parameter value", "Parameter unit", "N of in vitro experiments"])

# Sending the query
query_data = queryData(
    fivedbDBManager,
    user_process_types,
    user_parameters,
    user_cell_types,
    user_stimulateds,
    user_patient_states,
    user_products,
    user_daughter_cells,
    user_regulators,
    user_modifiers,
    selected_variables,
    "false"
)

print(query_data)

# Save query_data to a CSV file
CSV.write(joinpath(script_dir, "fivedb_query_data_jl.csv"), query_data, transform=(col, val) -> something(val, missing))
