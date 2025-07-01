if (!requireNamespace("httr", quietly = TRUE)) {
  install.packages("httr")
}
if (!requireNamespace("jsonlite", quietly = TRUE)) {
  install.packages("jsonlite")
}
if (!requireNamespace("lubridate", quietly = TRUE)) {
  install.packages("lubridate")
}
library(httr)
library(jsonlite)
library(lubridate)

# Class definitions
APICallResult <- setRefClass(
  "APICallResult",
  fields = list(
    content = "character",
    response = "ANY"
  )
)

BearerRequestToken <- setRefClass(
  "BearerRequestToken",
  fields = list(
    token = "character",
    expires_in ="POSIXct", 
    response = "ANY"
  )
)

DBManagerBase <- setRefClass(
  "DBManagerBase",
  fields = list(
    url = "character",
    path_to_credentials = "character",
    token = "ANY",
    headers_df = "data.frame"  # Added headers_df field    
  ),
  methods = list(
    initialize = function(url, path_to_credentials, token = NULL) {
      .self$url <- url
      .self$path_to_credentials <- path_to_credentials
      .self$token <- token
      message("DBManagerBase initialized with URL: ", url)
    },
    
    getAuthTokenPath = function(system_type) {
      temp_path <- tempdir()
      token_file_path <- file.path(temp_path, paste("token_cache_", system_type, ".rds"))
      return(token_file_path)
    },

    resetAuthToken = function(system_type) {
      message("Resetting authentication token...")
      
      # Get the path to the authentication token file
      token_file_path <- .self$getAuthTokenPath(system_type)
      
      # Check if the file exists before attempting to delete it
      if (file.exists(token_file_path)) {
        # Delete the file
        file.remove(token_file_path)
        message("Authentication token file deleted successfully.")
      } else {
        message("No authentication token file found at the specified path.")
      }
    },

    requestAuthToken = function(system_type) {
      message("Requesting authentication token...")
      token_file_path <- .self$getAuthTokenPath(system_type)
      if (file.exists(token_file_path)) {
        cached_token <- readRDS(token_file_path)
        if (cached_token$expires_in > Sys.time()) {
          message("Using cached token.")
          .self$token <- cached_token
          return(.self$token)
        }
      }
      
      credentials <- readLines(.self$path_to_credentials)
      credentials_data <- unlist(strsplit(credentials[1], " "))
      username <- credentials_data[1]
      password <- credentials_data[2]
      
      .self$token <- NULL
      
      body <- list(
        grant_type = 'password',
        client_id = username,
        client_secret = password,
        password = password,
        username = username
      )
      
      post_token_response <- POST(
        paste0(.self$url, "/oauth/token"),
        body = body,
        encode = "form"
      )
      
      if (status_code(post_token_response) == 200) {
        message("Authentication token received successfully.")
        post_token_response_content <- content(post_token_response, "parsed")
        
        if (is.null(post_token_response_content$access_token)) {
          stop("Access token is missing in the API response.")
        }
        if (is.null(post_token_response_content$expires_in)) {
          stop("Expires_in is missing in the API response.")
        }
        
        token_expire_time <- Sys.time() + seconds(as.integer(post_token_response_content$expires_in))
        
        .self$token <- BearerRequestToken$new(
          token = post_token_response_content$access_token,
          expires_in = token_expire_time,
          response = post_token_response
        )
        
        saveRDS(.self$token, token_file_path)
        message("Token saved to disk.")
      } else {
        warning("Failed to receive authentication token. Status code: ", status_code(post_token_response))
        .self$token <- BearerRequestToken$new(
          token = '',
          response = post_token_response
        )
      }
      
      return(.self$token)
    },
    
    isAuthenticated = function() {
      if (!is.null(.self$token) && .self$token$token != '') {
        message("User is authenticated.")
        return(TRUE)
      }
      message("User is not authenticated.")
      return(FALSE)
    },
    
    doAPICall = function(url, system_type, params = list()) {
      message("Making API call to: ", url)
      if (!.self$isAuthenticated()) {
        message("User is not authenticated. Requesting token...")
        requestToken <- .self$requestAuthToken(system_type)
        if (requestToken$token == '') {
          stop("User is not authenticated. Token request failed...")
        }
      }
      
      post_apicall_response <- GET(
        paste0(.self$url, url),
        body = params,
        add_headers(Authorization = paste("Bearer", .self$token$token))
      )
      
      response_content <- content(post_apicall_response, "text")
      if (is.null(response_content) || nchar(response_content) == 0) {
        warning("Empty response content from API.")
        response_content <- ""
      }
      
      return(
        APICallResult$new(
          content = response_content,
          response = post_apicall_response
        )
      )
    },
    
    getDictionary = function(url, dictionary_name, system_type, force = FALSE) {
      temp_path <- tempdir()
      cache_file_path <- file.path(temp_path, paste0(dictionary_name,"_", system_type, ".rds"))
      
      if (file.exists(cache_file_path) && !force) {
        message("Loading dictionary from cache...")
        return(readRDS(cache_file_path))
      }
      
      message("Fetching dictionary data...")
      apiCallResult <- .self$doAPICall(url, system_type, list())
      
      if (status_code(apiCallResult$response) == 200) {
        message("Dictionary data fetched successfully.")
        content <- apiCallResult$content
        if (nchar(content) > 0) {
          dictionary_data <- fromJSON(content)$Name
          saveRDS(dictionary_data, cache_file_path)
          message("Dictionary saved to cache at: ", cache_file_path)
          return(dictionary_data)
        } else {
          warning("Empty response from API.")
          return(NULL)
        }
      } else {
        warning("Failed to fetch dictionary data. Status code: ", status_code(apiCallResult$response))
        return(NULL)
      }
    },
    
    selectElements = function(user_elements, db_elements, caption) {
      missing <- setdiff(user_elements, db_elements)
      if (length(missing) > 0) {
        stop("Error: following ", caption, " not found: ", paste(missing, collapse = ", "), " in database.")      
      }
      return(user_elements[!is.na(user_elements)])
    },
    
    SelectHeader = function(column_descriptions) {
      # Check if headers are loaded
      if (is.null(.self$headers_df) || nrow(.self$headers_df) == 0) {
        stop("Headers not loaded. Use getQueryHeaders method to load data.")
      }
      
      # Find ColumnVariable for each ColumnDesc
      selected_variables <- sapply(column_descriptions, function(desc) {
        match <- .self$headers_df$ColumnVariable[.self$headers_df$ColumnDesc == desc]
        if (length(match) > 0) {
          return(match[1])  # Return first matching element
        } else {
          stop("Column description '", desc, "' not found.")
        }
      })
      
      return(selected_variables)
    },
    
    saveHeaders = function(file_path) {
      # Check that headers_df exists and contains ColumnDesc column
      if (is.null(headers_df)) {
        stop("headers_df is NULL. No data to save.")
      }
      if (!"ColumnDesc" %in% colnames(headers_df)) {
        stop("Column 'ColumnDesc' not found in headers_df.")
      }
      
      # Extract ColumnDesc column and save it to text file
      variable_desc <- headers_df$ColumnDesc
      writeLines(variable_desc, con = file_path)
      message("Column 'ColumnDesc' successfully saved to file: ", file_path)
    }
  )
)


# CytoconDBManager class inheriting from DBManagerBase
CytoconDBManager <- setRefClass(
  "CytoconDBManager",
  contains = "DBManagerBase",
  fields = list(
    diseases = "character",
    tissues_types = "character",
    species = "character",
    markers = "character",
    disease_attributes = "character",
    patient_group_attributes = "character"
  ),
  methods = list(
    initialize = function(url, path_to_credentials) {
      callSuper(url = url, path_to_credentials = path_to_credentials, token = NULL)
      message("CytoconDBManager initialized.")
    },
    
    getDiseases = function(force = FALSE) {
        return(.self$getDictionary("/api/v1/diseases", "diseases", 'cytocon', force))
    },
    
    getTissueTypes = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/tissues_types", "tissues_types", 'cytocon', force))
    },
    
    getSpecies = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/species", "species", 'cytocon', force))
    },
    
    getMarkers = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/markers", "markers", 'cytocon', force))
    },
    
    getDiseaseAttributes = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/disease_attributes", "disease_attributes", 'cytocon', force))
    },
    
    getPatientGroupAttributes = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/patient_group_attributes", "patient_group_attributes", 'cytocon', force))
    },
    
    loadDictionaries = function(force = FALSE) {
      .self$diseases <- .self$getDiseases(force)
      .self$tissues_types <- .self$getTissueTypes(force)
      .self$species <- .self$getSpecies(force)
      .self$markers <- .self$getMarkers(force)
      .self$disease_attributes <- .self$getDiseaseAttributes(force)
      .self$patient_group_attributes <- .self$getPatientGroupAttributes(force)
    },
    
    saveDictionaryToTextFile = function(dictionary, file_path, caption) {
      writeLines(dictionary, con = file_path)
      message("Dictionary '", caption, "' successfully saved to text file: ", file_path)
    },    

    
    checkDictionary = function(dictionary, caption) {
      if (is.null(dictionary) || length(dictionary) == 0) {
        message("Dictionary ", caption," is empty. Loading dictionaries...")
        .self$loadDictionaries()  # Call dictionary loading method
      }      
    },

    selectDiseases = function(diseases) {
      .self$checkDictionary(.self$diseases, 'diseases')
      return(.self$selectElements(diseases, .self$diseases, 'diseases'))
    },
    
    selectTissuesTypes = function(tissues_types) {
      .self$checkDictionary(.self$tissues_types, 'tissues types')
      return(.self$selectElements(tissues_types, .self$tissues_types, 'tissues types'))
    },
    
    selectSpecies = function(species) {
      .self$checkDictionary(.self$species, 'species')
      return(.self$selectElements(species, .self$species, 'species'))
    },
    
    selectMarkers = function(markers) {
      .self$checkDictionary(.self$markers, 'markers')
      return(.self$selectElements(markers, .self$markers, 'markers'))
    },
    
    saveDiseases = function(file_path) {
      .self$checkDictionary(.self$diseases, 'diseases')
      .self$saveDictionaryToTextFile(.self$diseases, file_path, 'diseases')
    },
    
    saveTissuesTypes = function(file_path) {
      .self$checkDictionary(.self$tissues_types, 'tissues types')
      .self$saveDictionaryToTextFile(.self$tissues_types, file_path, 'tissues types')
    },
    
    saveSpecies = function(file_path) {
      .self$checkDictionary(.self$species, 'species')
      .self$saveDictionaryToTextFile(.self$species, file_path, 'species')
    },
    
    saveMarkers = function(file_path) {
      .self$checkDictionary(.self$markers, 'markers')
      .self$saveDictionaryToTextFile(.self$markers, file_path, 'markers')
    },

    queryData = function(species, tissue_types, diseases, markers, headers, wstat_switch = "false" ) {

      params <- list(
        tissue_types = paste(tissue_types, collapse = ","),
        diseases = paste(diseases, collapse = ","),
        species = paste(species, collapse = ",") ,
        markers = paste(markers, collapse = ",") ,
        headers = paste(headers, collapse = ",") ,
        wstatSwitch = wstat_switch
      )
      
      query_string <- paste(
        names(params),
        sapply(params, URLencode, reserved = TRUE),
        sep = "=",
        collapse = "&"
      )    

      apiCallResult <- .self$doAPICall(
        url = paste0("/api/v1/query_data", "?", query_string),
        system_type = 'cytocon'
      )
      
      if (status_code(apiCallResult$response) == 200) {
        message("query data fetched successfully.")
        if (nchar(apiCallResult$content) > 0) {
          return(fromJSON(apiCallResult$content)) 
        } else {
          warning("Empty response from API.")
          return(NULL)
        }
        
      } else if (status_code(apiCallResult$response) == 400) {
          warning("Invalid arguments: ", apiCallResult$content)
          return(NULL) 
      } else {
        warning("Failed to fetch query data.", apiCallResult$content)
        return(NULL)
      }
    },
    
    queryHeaders = function(diseases, force = FALSE) {
      # Cache file path
      cache_dir <- tempdir()  # Can be replaced with any other path
      cache_file <- file.path(cache_dir, paste0("query_headers_", diseases, ".rds"))
      
      # If force = FALSE and cache exists, load data from cache
      if (!force && file.exists(cache_file)) {
        message("Loading data from cache...")
        .self$headers_df <- readRDS(cache_file)
        return(.self$headers_df)
      }
      
      # If force = TRUE or cache doesn't exist, make API request
      message("Making API request...")
      apiCallResult <- .self$doAPICall(
        url = paste0("/api/v1/query_data_headers?diseases=", URLencode(diseases)),
        system_type = 'cytocon'
      )
      
      # Check response status
      if (status_code(apiCallResult$response) == 200) {
        # Parse JSON response
        response_content <- fromJSON(apiCallResult$content)
        
        # Check response structure
        if (is.data.frame(response_content) && all(c("ColumnVariable", "ColumnDesc") %in% colnames(response_content))) {
          # If response is already a data.frame, use it
          .self$headers_df <- response_content
        } else if (is.list(response_content) && all(c("ColumnVariable", "ColumnDesc") %in% names(response_content[[1]]))) {
          # If response is a list, convert it to data.frame
          .self$headers_df <- data.frame(
            ColumnVariable = sapply(response_content, function(x) x$ColumnVariable),
            ColumnDesc = sapply(response_content, function(x) x$ColumnDesc)
          )
        } else {
          warning("Invalid JSON response structure.")
          return(NULL)
        }
        
        # Save data to cache
        saveRDS(.self$headers_df, file = cache_file)
        message("Data saved to cache: ", cache_file)
        
        # Return result
        return(.self$headers_df)
      } else {
        warning("Error while fetching data. Status code: ", status_code(apiCallResult$response))
        return(NULL)
      }
    }
  )
)

# FIVEDBManager class inheriting from DBManagerBase
FIVEDBManager <- setRefClass(
  "FIVEDBManager",
  contains = "DBManagerBase",
  fields = list(
    process_types = "character",
    parameters = "character",
    cell_types = "character",
    stimulateds = "character",
    patient_states = "character",
    products = "character",
    daughter_cells = "character",
    regulators = "character",
    modifiers = "character"
  ),
  
  methods = list(
    initialize = function(url, path_to_credentials) {
      callSuper(url = url, path_to_credentials = path_to_credentials, token = NULL)
      message("FIVEDBManager initialized.")
    },
    
    getProcessTypes = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/process_types", "process_types", 'fivedb', force))
    },
    
    getParameters = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/parameters", "parameters", 'fivedb', force))
    },
    
    getCellTypes = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/сell_types", "сell_types", 'fivedb', force))
    },
    
    getStimulated = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/stimulated", "stimulated", 'fivedb', force))
    },
    
    getPatientStates = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/patient_states", "patient_states", 'fivedb', force))
    },
    
    getProducts = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/products", "products", 'fivedb', force))
    },
    
    getDaughterCells = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/daughter_cells", "daughter_cells", 'fivedb', force))
    },
    
    getRegulators = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/regulators", "regulators", 'fivedb', force))
    },
    
    getModifiers = function(force = FALSE) {
      return(.self$getDictionary("/api/v1/modifiers", "modifiers", 'fivedb', force))
    },
    
    loadDictionaries = function(force = FALSE) {
      .self$process_types <- .self$getProcessTypes(force)
      .self$parameters <- .self$getParameters(force)
      .self$cell_types <- .self$getCellTypes(force)
      .self$stimulateds <- .self$getStimulated(force)
      .self$patient_states <- .self$getPatientStates(force)
      .self$products <- .self$getProducts(force)
      .self$daughter_cells <- .self$getDaughterCells(force)
      .self$regulators <- .self$getRegulators(force)
      .self$modifiers <- .self$getModifiers(force)
    },
    
    saveDictionaryToTextFile = function(dictionary, file_path, caption) {
      writeLines(dictionary, con = file_path)
      message("Dictionary '", caption, "' successfully saved to text file: ", file_path)
    },    
    
    
    checkDictionary = function(dictionary, caption) {
      if (is.null(dictionary) || length(dictionary) == 0) {
        message("Dictionary ", caption," is empty. Loading dictionaries...")
        .self$loadDictionaries()  # Call dictionary loading method
      }      
    },
    
    selectProcessTypes = function(process_types) {
      .self$checkDictionary(.self$process_types, 'process_types')
      return(.self$selectElements(process_types, .self$process_types, 'process_types'))
    },
    
    selectParameters = function(parameters) {
      .self$checkDictionary(.self$parameters, 'parameters')
      return(.self$selectElements(parameters, .self$parameters, 'parameters'))
    },
    
    selectCellTypes = function(cell_types) {
      .self$checkDictionary(.self$cell_types, 'cell_types')
      return(.self$selectElements(cell_types, .self$cell_types, 'cell_types'))
    },
    
    selectStimulated = function(stimulateds) {
      .self$checkDictionary(.self$stimulateds, 'stimulateds')
      return(.self$selectElements(stimulateds, .self$stimulateds, 'stimulateds'))
    },
    
    selectPatientStates = function(patient_states) {
      .self$checkDictionary(.self$patient_states, 'patient_states')
      return(.self$selectElements(patient_states, .self$patient_states, 'patient_states'))
    },
    
    selectProducts = function(products) {
      .self$checkDictionary(.self$products, 'products')
      return(.self$selectElements(products, .self$products, 'products'))
    },
    
    selectDaughterCells = function(daughter_cells) {
      .self$checkDictionary(.self$daughter_cells, 'daughter_cells')
      return(.self$selectElements(daughter_cells, .self$daughter_cells, 'daughter_cells'))
    },
    
    selectRegulators = function(regulators) {
      .self$checkDictionary(.self$regulators, 'regulators')
      return(.self$selectElements(regulators, .self$regulators, 'regulators'))
    },
    
    selectModifiers = function(modifiers) {
      .self$checkDictionary(.self$modifiers, 'modifiers')
      return(.self$selectElements(modifiers, .self$modifiers, 'modifiers'))
    },
    
    saveProcessTypes = function(file_path) {
      .self$checkDictionary(.self$process_types, 'process_types')
      .self$saveDictionaryToTextFile(.self$process_types, file_path, 'process_types')
    },
    
    saveParameters = function(file_path) {
      .self$checkDictionary(.self$parameters, 'parameters')
      .self$saveDictionaryToTextFile(.self$parameters, file_path, 'parameters')
    },
    
    saveCellTypes = function(file_path) {
      .self$checkDictionary(.self$cell_types, 'cell_types')
      .self$saveDictionaryToTextFile(.self$cell_types, file_path, 'cell_types')
    },
    
    saveStimulateds = function(file_path) {
      .self$checkDictionary(.self$stimulateds, 'stimulateds')
      .self$saveDictionaryToTextFile(.self$stimulateds, file_path, 'stimulateds')
    },
    
    savePatientStates = function(file_path) {
      .self$checkDictionary(.self$patient_states, 'patient_states')
      .self$saveDictionaryToTextFile(.self$patient_states, file_path, 'patient_states')
    },
    
    saveProducts = function(file_path) {
      .self$checkDictionary(.self$products, 'products')
      .self$saveDictionaryToTextFile(.self$products, file_path, 'products')
    },
    
    saveDaughterCells = function(file_path) {
      .self$checkDictionary(.self$daughter_cells, 'daughter_cells')
      .self$saveDictionaryToTextFile(.self$daughter_cells, file_path, 'daughter_cells')
    },
    
    saveRegulators = function(file_path) {
      .self$checkDictionary(.self$regulators, 'regulators')
      .self$saveDictionaryToTextFile(.self$regulators, file_path, 'regulators')
    },
    
    saveModifiers = function(file_path) {
      .self$checkDictionary(.self$modifiers, 'modifiers')
      .self$saveDictionaryToTextFile(.self$modifiers, file_path, 'modifiers')
    },
    
    queryData = function(process_type, parameter, cell_type, stimulated, 
                         patient_state, product, daughter, regulator, 
                         modifier, headers, wstat_switch = "false" ) {
      
      params <- list(
        process_type = paste(process_type, collapse = ","),
        parameter = paste(parameter, collapse = ","),
        cell_type = paste(cell_type, collapse = ",") ,
        stimulated = paste(stimulated, collapse = ",") ,
        
        patient_state = paste(patient_state, collapse = ",") ,
        product = paste(product, collapse = ",") ,
        daughter = paste(daughter, collapse = ",") ,
        regulator = paste(regulator, collapse = ",") ,
        
        modifier = paste(modifier, collapse = ",") ,
        headers = paste(headers, collapse = ",") ,
        wstatSwitch = wstat_switch
      )
      
      query_string <- paste(
        names(params),
        sapply(params, URLencode, reserved = TRUE),
        sep = "=",
        collapse = "&"
      )    
      
      apiCallResult <- .self$doAPICall(
        url = paste0("/api/v1/query_data", "?", query_string),
        system_type = "fivedb"
      )
      
      if (status_code(apiCallResult$response) == 200) {
        message("query data fetched successfully.")
        if (nchar(apiCallResult$content) > 0) {
          return(fromJSON(apiCallResult$content)) 
        } else {
          warning("Empty response from API.")
          return(NULL)
        }
        
      } else if (status_code(apiCallResult$response) == 400) {
        warning("Invalid arguments: ", apiCallResult$content)
        return(NULL) 
      } else {
        warning("Failed to fetch query data.", apiCallResult$content)
        return(NULL)
      }
    },
    
    queryHeaders = function(force = FALSE) {
      # Cache file path
      cache_dir <- tempdir()  # Can be replaced with any other path
      cache_file <- file.path(cache_dir, paste0("query_headers_5db.rds"))
      
      # If force = FALSE and cache exists, load data from cache
      if (!force && file.exists(cache_file)) {
        message("Loading data from cache...")
        .self$headers_df <- readRDS(cache_file)
        return(.self$headers_df)
      }
      
      # If force = TRUE or cache doesn't exist, make API request
      message("Making API request...")
      apiCallResult <- .self$doAPICall(
        url = paste0("/api/v1/query_data_headers"),
        system_type = 'fivedb'
      )
      
      # Check response status
      if (status_code(apiCallResult$response) == 200) {
        # Parse JSON response
        response_content <- fromJSON(apiCallResult$content)
        
        # Check response structure
        if (is.data.frame(response_content) && all(c("ColumnVariable", "ColumnDesc") %in% colnames(response_content))) {
          # If response is already a data.frame, use it
          .self$headers_df <- response_content
        } else if (is.list(response_content) && all(c("ColumnVariable", "ColumnDesc") %in% names(response_content[[1]]))) {
          # If response is a list, convert it to data.frame
          .self$headers_df <- data.frame(
            ColumnVariable = sapply(response_content, function(x) x$ColumnVariable),
            ColumnDesc = sapply(response_content, function(x) x$ColumnDesc)
          )
        } else {
          warning("Invalid JSON response structure.")
          return(NULL)
        }
        
        # Save data to cache
        saveRDS(.self$headers_df, file = cache_file)
        message("Data saved to cache: ", cache_file)
        
        # Return result
        return(.self$headers_df)
      } else {
        warning("Error while fetching data. Status code: ", status_code(apiCallResult$response))
        return(NULL)
      }
    }
  )
)
