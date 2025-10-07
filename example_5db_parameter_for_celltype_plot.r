# Example of Querying the Insysbio FIVEDB Database via R Script

# This R script performs the following operations:

# 1. Connecting to FIVEDB and Loading Reference Data
#    - Authenticates with the FIVEDB database via REST API using provided credentials
#    - Downloads metadata: lists of process types, parameters, cell types, stimulated factors,
#      patient states, products, regulators, modifiers, and daughter cells
#    - Saves these reference datasets as local files for future use

# 2. Constructing and Executing a Query
#    - Selects specific process types (e.g., Migration)
#    - Selects specific parameters (e.g., Emax)
#    - Leaves other parameters (cell types, stimulated factors, patient states, products,
#      regulators, modifiers, daughter cells) unrestricted
#    - Requests specific data columns:
#      * Parameter name
#      * Parameter value
#      * Parameter unit
#      * Number of in vitro experiments

# 3. Saving the Results
#    - Exports results to CSV file (fivedb_query_data_r.csv) for further analysis

# Summary:
# Automates data extraction from FIVEDB, enabling efficient retrieval
# of structured biological data in an analysis-ready format

if (!requireNamespace("ggplot2", quietly = TRUE)) {
  install.packages("ggplot2")
}
library(ggplot2)

if (!requireNamespace("this.path", quietly = TRUE)) {
  install.packages("this.path")
}
# Load the this.path package
library(this.path)

# Get the full path of the current script
script_path <- this.path::this.path()
print(file.path(dirname(script_path), "insysbio_db.r"))

# Source another script in the same directory
source(file.path(dirname(script_path), "insysbio_db.r"))

path_to_dict = "./"
path_to_fivedb_credentials = file.path(dirname(script_path), "fivedb_credentials.txt")
fivedb_url = "https://dev5db.insysbio.com"   

# Creating FIVEDBManager instance and fetching 5db dictionaries data
message("Creating FIVEDBManager instance...")
fiveDBManager <- FIVEDBManager$new(
  url = fivedb_url,
  path_to_credentials = path_to_fivedb_credentials
)
message("Fetching 5db dictionaries data...")
fiveDBManager$loadDictionaries()

# Saving dictionaries to disk for easy lookup
fiveDBManager$saveProcessTypes(file.path(dirname(script_path),'5db_process_types.r.txt'))
fiveDBManager$saveParameters(file.path(dirname(script_path),'5db_parameters.r.txt'))
fiveDBManager$saveCellTypes(file.path(dirname(script_path),'5db_cell_types.r.txt'))

fiveDBManager$saveStimulateds(file.path(dirname(script_path),'5db_stimulateds.r.txt'))
fiveDBManager$savePatientStates(file.path(dirname(script_path),'5db_patient_states.r.txt'))

fiveDBManager$saveProducts(file.path(dirname(script_path),'5db_products.r.txt'))
fiveDBManager$saveDaughterCells(file.path(dirname(script_path),'5db_daughter_cells.r.txt'))

fiveDBManager$saveRegulators(file.path(dirname(script_path),'5db_regulators.r.txt'))
fiveDBManager$saveModifiers(file.path(dirname(script_path),'5db_modifiers.r.txt'))

# Selecting what we need to find

user_process_types <- fiveDBManager$selectProcessTypes(c('Secretion'))
user_parameters <- fiveDBManager$selectParameters(c('kbase', 'Kmax'))
user_cell_types <- fiveDBManager$selectCellTypes(c('Macrophages'))

user_stimulateds <- fiveDBManager$selectStimulated(c())
user_patient_states <- fiveDBManager$selectPatientStates(c())
user_products <- fiveDBManager$selectProducts(c('IL6'))
user_daughter_cells <- fiveDBManager$selectDaughterCells(c())

user_regulators <- fiveDBManager$selectRegulators(c())
user_modifiers <- fiveDBManager$selectModifiers(c())

# Saving column names to disk for convenience
fiveDBManager$queryHeaders(force = FALSE)
fiveDBManager$saveHeaders(file.path(dirname(script_path),'5db_headers.r.txt'))

# Selecting columns that should go into the output
selected_variables <- fiveDBManager$SelectHeader(c('Parameter','Parameter value', 'Cell DB type','Cell product'))

# Sending the query
query_data_5db <- fiveDBManager$queryData(
  process_type = user_process_types, 
  parameter = user_parameters, 
  cell_type = user_cell_types, 
  stimulated = user_stimulateds,
  patient_state = user_patient_states,
  product = user_products,
  daughter = user_daughter_cells,
  regulator = user_regulators,
  modifier = user_modifiers,
  headers=selected_variables,
  wstat_switch = "false"
)

# Stop execution if the query returns NULL
if (is.null(query_data_5db)) {
  stop("Query error")
}

param_var = selected_variables["Parameter value"]
cell_type_var = selected_variables["Cell DB type"]
print(param_var)
print(cell_type_var)


# Add a column with measurement ID (row sequence number)
query_data_5db$MeasurementID <- seq_len(nrow(query_data_5db))

print(query_data_5db)
# Create a plot of parameter vs measurement number
p <- ggplot(query_data_5db, aes(x = MeasurementID, y = .data[[param_var]])) +
  geom_point(aes(color = .data[[cell_type_var]]), size = 2) +
  geom_line(alpha = 0.5) +
  scale_y_log10() +
  labs(
    title = "Parameter value by measurement number",
    x = "Measurement number",
    y = "Parameter value (log scale)",
    color = "Cell type",
    caption = paste("Parameter:", user_parameters)
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(hjust = 0.5),
    legend.position = "bottom"
  )

print(p)
