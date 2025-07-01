"""
Example of Querying the Insysbio FIVEDB Database via REST API

This Python script performs the following operations:

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
   - Exports results to CSV file (fivedb_query_data_py.csv) for further analysis

Summary:
Automates data extraction from FIVEDB, enabling efficient retrieval
of structured biological data in an analysis-ready format
"""

import os
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
from insysbio_db import *

# Example usage
if __name__ == "__main__":

    script_dir = os.path.dirname(os.path.abspath(__file__))
    path_to_dict = script_dir
    path_to_fivedb_credentials = os.path.join(script_dir, "fivedb_credentials.txt")
    fivedb_url = "https://dev5db.insysbio.com"   

    print("Creating FIVEDBManager instance...")
    fiveDBManager = FIVEDBManager(
        url=fivedb_url,
        path_to_credentials=path_to_fivedb_credentials
    )
    # fiveDBManager.reset_auth_token()
    print("Loading dictionaries...")
    fiveDBManager.load_dictionaries()

    # Save dictionaries to disk
    fiveDBManager.save_process_types(os.path.join(path_to_dict,'5db_process_types.py.txt'))
    fiveDBManager.save_parameters(os.path.join(path_to_dict,'5db_parameters.py.txt'))
    fiveDBManager.save_cell_types(os.path.join(path_to_dict,'5db_cell_types.py.txt'))
    fiveDBManager.save_stimulateds(os.path.join(path_to_dict,'5db_stimulateds.py.txt'))
    fiveDBManager.save_patient_states(os.path.join(path_to_dict,'5db_patient_states.py.txt'))
    fiveDBManager.save_products(os.path.join(path_to_dict,'5db_products.py.txt'))
    fiveDBManager.save_daughter_cells(os.path.join(path_to_dict,'5db_daughter_cells.py.txt'))
    fiveDBManager.save_regulators(os.path.join(path_to_dict,'5db_regulators.py.txt'))
    fiveDBManager.save_modifiers(os.path.join(path_to_dict,'5db_modifiers.py.txt'))

    # Select what we need to find
    user_process_types = fiveDBManager.select_process_types(['Migration'])
    user_parameters = fiveDBManager.select_parameters(['Emax'])
    user_cell_types = fiveDBManager.select_cell_types([])
    user_stimulateds = fiveDBManager.select_stimulated([])
    user_patient_states = fiveDBManager.select_patient_states([])
    user_products = fiveDBManager.select_products([])
    user_daughter_cells = fiveDBManager.select_daughter_cells([])
    user_regulators = fiveDBManager.select_regulators([])
    user_modifiers = fiveDBManager.select_modifiers([])

    # Save column names to disk for easy selection
    fiveDBManager.query_headers(force=True)
    fiveDBManager.save_headers(os.path.join(path_to_dict,'5db_headers.py.txt'))

    # Select columns for output
    selected_variables = fiveDBManager.select_header(['Parameter', 'Parameter value', 'N of in vitro experiments', 'Parameter unit'])

    # Send the query
    query_data_5db = fiveDBManager.query_data(
        process_type=user_process_types,
        parameter=user_parameters,
        cell_type=user_cell_types,
        stimulated=user_stimulateds,
        patient_state=user_patient_states,
        product=user_products,
        daughter=user_daughter_cells,
        regulator=user_regulators,
        modifier=user_modifiers,
        headers=selected_variables,
        wstat_switch="false"
    )

    if query_data_5db is None:
        raise ValueError("Query error")

    print(query_data_5db)

    # Save query_data to a CSV file
    query_data_5db.to_csv(os.path.join(path_to_dict, "fivedb_query_data_py.csv"), index=False)


