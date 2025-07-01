import os
import tempfile
import requests
import json
from datetime import datetime, timedelta
import pandas as pd
from typing import List, Dict, Optional

# Class to store API call results
class APICallResult:
    def __init__(self, content, response):
        self.content = content
        self.response = response

# Class to store bearer token information
class BearerRequestToken:
    def __init__(self, token, expires_in, response):
        self.token = token
        self.expires_in = expires_in
        self.response = response

# Base class for database management
class DBManagerBase:
    def __init__(self, url, path_to_credentials, token=None):
        self.url = url
        self.path_to_credentials = path_to_credentials
        self.token = token
        self.system_type = "unknown"
        self.headers_df = pd.DataFrame()  # For storing headers
        print(f"DBManagerBase initialized with URL: {url}")

    def select_elements(self, user_elements, db_elements, caption):
        """
        Selects elements from user_elements that exist in db_elements.
        Raises an exception if any elements are missing.
        """
        missing = set(user_elements) - set(db_elements)
        if missing:
            raise ValueError(f"Error: the following {caption} were not found: {', '.join(missing)}")
        return [element for element in user_elements if element in db_elements]

    def get_auth_token_path(self):
        temp_path = tempfile.gettempdir()
        token_file_path = os.path.join(temp_path, f"token_cache_{self.system_type}.json")
        return token_file_path

    def reset_auth_token(self):
        print("Resetting authentication token...")
    
        # Get the path to the authentication token file
        token_file_path = self.get_auth_token_path()
    
        # Check if file exists before attempting deletion
        if os.path.exists(token_file_path):
            os.remove(token_file_path)
            print("Authentication token file deleted successfully.")
        else:
            print("No authentication token file found at the specified path.")

    def request_auth_token(self):
        print("Requesting authentication token...")
        token_file_path = self.get_auth_token_path()

        # Check token cache
        if os.path.exists(token_file_path):
            with open(token_file_path, "r") as f:
                cached_token = json.load(f)
                expires_in = datetime.fromisoformat(cached_token["expires_in"])
                if expires_in > datetime.now():
                    print("Using cached token.")
                    self.token = BearerRequestToken(
                        token=cached_token["token"],
                        expires_in=expires_in,
                        response=None
                    )
                    return self.token

        # Read credentials
        with open(self.path_to_credentials, "r") as f:
            credentials = f.readline().strip().split(" ")
            username, password = credentials[0], credentials[1]

        # Request token
        body = {
            "grant_type": "password",
            "client_id": username,
            "client_secret": password,
            "username": username,
            "password": password
        }
        response = requests.post(f"{self.url}/oauth/token", data=body)

        if response.status_code == 200:
            print("Authentication token received successfully.")
            response_data = response.json()
            if "access_token" not in response_data or "expires_in" not in response_data:
                raise ValueError("Access token or expires_in is missing in the API response.")

            expires_in = datetime.now() + timedelta(seconds=int(response_data["expires_in"]))
            self.token = BearerRequestToken(
                token=response_data["access_token"],
                expires_in=expires_in,
                response=response
            )

            # Cache the token
            with open(token_file_path, "w") as f:
                json.dump({
                    "token": self.token.token,
                    "expires_in": self.token.expires_in.isoformat()
                }, f)
            print("Token saved to disk.")
        else:
            print(f"Failed to receive authentication token. Status code: {response.status_code}")
            self.token = BearerRequestToken(token="", expires_in=None, response=response)

        return self.token

    def is_authenticated(self):
        if self.token and self.token.token:
            print("User is authenticated.")
            return True
        print("User is not authenticated.")
        return False

    def do_api_call(self, url, params=None):
        print(f"Making API call to: {url}")
        if not self.is_authenticated():
            print("User is not authenticated. Requesting token...")
            self.request_auth_token()
            if not self.token.token:
                raise Exception("User is not authenticated. Token request failed.")

        headers = {"Authorization": f"Bearer {self.token.token}"}
        response = requests.get(f"{self.url}{url}", params=params, headers=headers)

        if response.status_code == 200:
            return APICallResult(content=response.text, response=response)
        else:
            print(f"API call failed. Status code: {response.status_code}")
            return APICallResult(content="", response=response)

    def get_dictionary(self, url, dictionary_name, force=False):
       temp_path = tempfile.gettempdir()
       cache_file_path = os.path.join(temp_path, f"{dictionary_name}.json")

       if not force and os.path.exists(cache_file_path):
           print("Loading dictionary from cache...")
           with open(cache_file_path, "r") as f:
                return json.load(f)

       print("Fetching dictionary data...")
       api_call_result = self.do_api_call(url)
       if api_call_result.response.status_code == 200:
            try:
                # Parse JSON response
                response_data = json.loads(api_call_result.content)
            
                # Check if response is a list
                if isinstance(response_data, list):
                    # Extract "Name" field from each item
                    dictionary_data = [item.get("Name") for item in response_data]
                elif isinstance(response_data, dict):
                    # Extract "Name" field
                    dictionary_data = response_data.get("Name", [])
                else:
                    raise ValueError("Unexpected JSON structure in API response.")
            
                # Cache the data
                with open(cache_file_path, "w") as f:
                    json.dump(dictionary_data, f)
                print(f"Dictionary saved to cache at: {cache_file_path}")
                return dictionary_data
            except json.JSONDecodeError as e:
                print(f"Failed to decode JSON response: {e}")
                return None
       else:
           print("Failed to fetch dictionary data.")
           return None

    def save_dictionary_to_text_file(self, dictionary, file_path, caption):
        try:
            with open(file_path, "w", encoding="utf-8") as f:
                f.write("\n".join(dictionary))
            print(f"Dictionary '{caption}' successfully saved to text file: {file_path}")
        except Exception as e:
            print(f"Failed to save dictionary to file: {e}")

    def check_dictionary(self, dictionary, caption):
        if not dictionary:
            print(f"Dictionary {caption} is empty. Loading dictionaries...")
            self.load_dictionaries()

    def save_headers(self, file_path):
        if self.headers_df.empty:
            raise ValueError("headers_df is empty or missing 'ColumnDesc' column.")
        with open(file_path, "w") as f:
            f.write("\n".join(self.headers_df["ColumnDesc"]))
        print(f"Column 'ColumnDesc' saved to file: {file_path}")
 
    def select_header(self, column_descriptions):
        if self.headers_df.empty:
            raise ValueError("Headers not loaded. Use query_headers to load data.")
        selected_variables = []
        for desc in column_descriptions:
            match = self.headers_df[self.headers_df["ColumnDesc"] == desc]["ColumnVariable"]
            if not match.empty:
                selected_variables.append(match.iloc[0])
            else:
                raise ValueError(f"Column description '{desc}' not found.")
        return selected_variables

# Cytocon database manager class inheriting from DBManagerBase
class CytoconDBManager(DBManagerBase):
    def __init__(self, url, path_to_credentials):
        super().__init__(url, path_to_credentials)
        self.diseases = []
        self.tissues_types = []
        self.species = []
        self.markers = []
        self.disease_attributes = []
        self.patient_group_attributes = []
        self.system_type = "cytocon"
        print("CytoconDBManager initialized.")

    def load_dictionaries(self, force=False):
        self.diseases = self.get_dictionary("/api/v1/diseases", "diseases", force)
        self.tissues_types = self.get_dictionary("/api/v1/tissues_types", "tissues_types", force)
        self.species = self.get_dictionary("/api/v1/species", "species", force)
        self.markers = self.get_dictionary("/api/v1/markers", "markers", force)
        self.disease_attributes = self.get_dictionary("/api/v1/disease_attributes", "disease_attributes", force)
        self.patient_group_attributes = self.get_dictionary("/api/v1/patient_group_attributes", "patient_group_attributes", force)

    def select_diseases(self, diseases):
        self.check_dictionary(self.diseases, "diseases")
        return self.select_elements(diseases, self.diseases, "diseases")

    def select_tissues_types(self, tissues_types):
        self.check_dictionary(self.tissues_types, "tissues types")
        return self.select_elements(tissues_types, self.tissues_types, "tissues types")

    def select_species(self, species):
        self.check_dictionary(self.species, "species")
        return self.select_elements(species, self.species, "species")

    def select_markers(self, markers):
        self.check_dictionary(self.markers, "markers")
        return self.select_elements(markers, self.markers, "markers")

    def save_diseases(self, file_path):
        self.check_dictionary(self.diseases, "diseases")
        self.save_dictionary_to_text_file(self.diseases, file_path, "diseases")

    def save_tissues_types(self, file_path):
        self.check_dictionary(self.tissues_types, "tissues types")
        self.save_dictionary_to_text_file(self.tissues_types, file_path, "tissues types")

    def save_species(self, file_path):
        self.check_dictionary(self.species, "species")
        self.save_dictionary_to_text_file(self.species, file_path, "species")

    def save_markers(self, file_path):
        self.check_dictionary(self.markers, "markers")
        self.save_dictionary_to_text_file(self.markers, file_path, "markers")

    def query_data(self, species, tissue_types, diseases, markers, headers, wstat_switch="false"):
        params = {
            "tissue_types": ",".join(tissue_types),
            "diseases": ",".join(diseases),
            "species": ",".join(species),
            "markers": ",".join(markers),
            "headers": ",".join(headers),
            "wstatSwitch": wstat_switch
        }
        api_call_result = self.do_api_call("/api/v1/query_data", params)
        if api_call_result.response.status_code == 200:
            return pd.DataFrame(json.loads(api_call_result.content))
        else:
            print("Failed to fetch query data.")
            return None

    def query_headers(self, diseases, force=False):
        cache_dir = tempfile.gettempdir()
        cache_file = os.path.join(cache_dir, f"query_headers_{diseases}.json")

        if not force and os.path.exists(cache_file):
            print("Loading data from cache...")
            with open(cache_file, "r") as f:
                self.headers_df = pd.DataFrame(json.load(f))
            return self.headers_df

        print("Making API request...")
        api_call_result = self.do_api_call(f"/api/v1/query_data_headers?diseases={diseases}")
        if api_call_result.response.status_code == 200:
            response_content = json.loads(api_call_result.content)
            if isinstance(response_content, list):
                self.headers_df = pd.DataFrame(response_content)
            else:
                self.headers_df = pd.DataFrame([response_content])
            with open(cache_file, "w") as f:
                json.dump(self.headers_df.to_dict(orient="records"), f)
            print(f"Data saved to cache: {cache_file}")
            return self.headers_df
        else:
            print(f"Failed to fetch data. Status code: {api_call_result.response.status_code}")
            return None

# FIVE database manager class
class FIVEDBManager(DBManagerBase):
    def __init__(self, url, path_to_credentials):
        super().__init__(url, path_to_credentials)
        self.process_types = []
        self.parameters = []
        self.cell_types = []
        self.stimulateds = []
        self.patient_states = []
        self.products = []
        self.daughter_cells = []
        self.regulators = []
        self.modifiers = []
        print("FIVEDBManager initialized.")

    def get_process_types(self, force=False):
        return self.get_dictionary("/api/v1/process_types", "process_types", force)

    def get_parameters(self, force=False):
        return self.get_dictionary("/api/v1/parameters", "parameters", force)

    def get_cell_types(self, force=False):
        return self.get_dictionary("/api/v1/сell_types", "сell_types", force)

    def get_stimulated(self, force=False):
        return self.get_dictionary("/api/v1/stimulated", "stimulated", force)

    def get_patient_states(self, force=False):
        return self.get_dictionary("/api/v1/patient_states", "patient_states", force)

    def get_products(self, force=False):
        return self.get_dictionary("/api/v1/products", "products", force)

    def get_daughter_cells(self, force=False):
        return self.get_dictionary("/api/v1/daughter_cells", "daughter_cells", force)

    def get_regulators(self, force=False):
        return self.get_dictionary("/api/v1/regulators", "regulators", force)

    def get_modifiers(self, force=False):
        return self.get_dictionary("/api/v1/modifiers", "modifiers", force)

    def load_dictionaries(self, force=False):
        self.process_types = self.get_process_types(force)
        self.parameters = self.get_parameters(force)
        self.cell_types = self.get_cell_types(force)
        self.stimulateds = self.get_stimulated(force)
        self.patient_states = self.get_patient_states(force)
        self.products = self.get_products(force)
        self.daughter_cells = self.get_daughter_cells(force)
        self.regulators = self.get_regulators(force)
        self.modifiers = self.get_modifiers(force)

    def select_process_types(self, process_types):
        self.check_dictionary(self.process_types, 'process_types')
        return self.select_elements(process_types, self.process_types, 'process_types')

    def select_parameters(self, parameters):
        self.check_dictionary(self.parameters, 'parameters')
        return self.select_elements(parameters, self.parameters, 'parameters')

    def select_cell_types(self, cell_types):
        self.check_dictionary(self.cell_types, 'cell_types')
        return self.select_elements(cell_types, self.cell_types, 'cell_types')

    def select_stimulated(self, stimulateds):
        self.check_dictionary(self.stimulateds, 'stimulateds')
        return self.select_elements(stimulateds, self.stimulateds, 'stimulateds')

    def select_patient_states(self, patient_states):
        self.check_dictionary(self.patient_states, 'patient_states')
        return self.select_elements(patient_states, self.patient_states, 'patient_states')

    def select_products(self, products):
        self.check_dictionary(self.products, 'products')
        return self.select_elements(products, self.products, 'products')

    def select_daughter_cells(self, daughter_cells):
        self.check_dictionary(self.daughter_cells, 'daughter_cells')
        return self.select_elements(daughter_cells, self.daughter_cells, 'daughter_cells')

    def select_regulators(self, regulators):
        self.check_dictionary(self.regulators, 'regulators')
        return self.select_elements(regulators, self.regulators, 'regulators')

    def select_modifiers(self, modifiers):
        self.check_dictionary(self.modifiers, 'modifiers')
        return self.select_elements(modifiers, self.modifiers, 'modifiers')

    def save_process_types(self, file_path):
        self.check_dictionary(self.process_types, 'process_types')
        self.save_dictionary_to_text_file(self.process_types, file_path, 'process_types')

    def save_parameters(self, file_path):
        self.check_dictionary(self.parameters, 'parameters')
        self.save_dictionary_to_text_file(self.parameters, file_path, 'parameters')

    def save_cell_types(self, file_path):
        self.check_dictionary(self.cell_types, 'cell_types')
        self.save_dictionary_to_text_file(self.cell_types, file_path, 'cell_types')

    def save_stimulateds(self, file_path):
        self.check_dictionary(self.stimulateds, 'stimulateds')
        self.save_dictionary_to_text_file(self.stimulateds, file_path, 'stimulateds')

    def save_patient_states(self, file_path):
        self.check_dictionary(self.patient_states, 'patient_states')
        self.save_dictionary_to_text_file(self.patient_states, file_path, 'patient_states')

    def save_products(self, file_path):
        self.check_dictionary(self.products, 'products')
        self.save_dictionary_to_text_file(self.products, file_path, 'products')

    def save_daughter_cells(self, file_path):
        self.check_dictionary(self.daughter_cells, 'daughter_cells')
        self.save_dictionary_to_text_file(self.daughter_cells, file_path, 'daughter_cells')

    def save_regulators(self, file_path):
        self.check_dictionary(self.regulators, 'regulators')
        self.save_dictionary_to_text_file(self.regulators, file_path, 'regulators')

    def save_modifiers(self, file_path):
        self.check_dictionary(self.modifiers, 'modifiers')
        self.save_dictionary_to_text_file(self.modifiers, file_path, 'modifiers')

    def query_data(self, process_type, parameter, cell_type, stimulated, patient_state, product, daughter, regulator, modifier, headers, wstat_switch="false"):
        params = {
            'process_type': ','.join(process_type),
            'parameter': ','.join(parameter),
            'cell_type': ','.join(cell_type),
            'stimulated': ','.join(stimulated),
            'patient_state': ','.join(patient_state),
            'product': ','.join(product),
            'daughter': ','.join(daughter),
            'regulator': ','.join(regulator),
            'modifier': ','.join(modifier),
            'headers': ','.join(headers),
            'wstatSwitch': wstat_switch
        }

        api_call_result = self.do_api_call("/api/v1/query_data", params)
        if api_call_result.response.status_code == 200:
            return pd.DataFrame(json.loads(api_call_result.content))
        else:
            print("Failed to fetch query data.")
            return None

    def query_headers(self, force=False):
        cache_dir = tempfile.gettempdir()
        cache_file = os.path.join(cache_dir, "query_headers_5db.json")

        if not force and os.path.exists(cache_file):
            print("Loading data from cache...")
            with open(cache_file, "r") as f:
                self.headers_df = pd.DataFrame(json.load(f))
            return self.headers_df

        print("Making API request...")
        api_call_result = self.do_api_call(
            url="/api/v1/query_data_headers"
        )

        if api_call_result.response.status_code == 200:
            response_content = json.loads(api_call_result.content)
            if isinstance(response_content, list):
                self.headers_df = pd.DataFrame(response_content)
            else:
                self.headers_df = pd.DataFrame([response_content])
            with open(cache_file, "w") as f:
                json.dump(self.headers_df.to_dict(orient="records"), f)
            print(f"Data saved to cache: {cache_file}")
            return self.headers_df
        else:
            print(f"Failed to fetch data. Status code: {api_call_result.response.status_code}")
            return None



