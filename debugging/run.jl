using TulipaEnergyModel
using TulipaIO
using DuckDB
using JuMP
using Gurobi
using CSV
using DataFrames
using Dates

experiment_inputs_dir = "debugging/experiment-inputs/modifiable-cases"
experiment_results_dir = "debugging/experiment-outputs"
log_file = "debugging/run.log"

case_studies_to_run = [
    "1var-0",
    "1var-E1C",
    "1var-E1CT",
    "1var-E2C",
    "1var-E2CT",
    "2var-0C",
    "2var-0T",
    "2var-E1",
    "2var-E2",
    "3var-0C",
    "3var-0T",
    "3var-0N",
    "3var-E1",
    "3var-E2",
    # "3var-E3",
]

# Create/Clear the log file
open(log_file, "w") do io
    println(io, "")
end

# Case_type is supposed to be brownfield-..., greenfield
# Case will be the nvar-En
case_types = readdir(experiment_inputs_dir)

for case_type in case_types
    for case in case_studies_to_run
        output_casetype_folder = joinpath(pwd(), experiment_results_dir, case_type)
        if !isdir(output_casetype_folder)
            mkpath(output_casetype_folder)
        end
        
        output_folder = joinpath(pwd(), experiment_results_dir, case_type, case)
        if !isdir(output_folder)
            mkpath(output_folder)
        end

        input_folder = joinpath(pwd(), experiment_inputs_dir, case_type)
        asset_file = joinpath(input_folder, "asset.csv")

        # Open database connection
        conn = DBInterface.connect(DuckDB.DB)
        

        # Take note of which case we are starting
        curr_time = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS.sss")
        open(log_file, "a") do io
            println(io, "$curr_time: Starting case: $case_type/$case")
        end
        
        # Modify asset.csv to have correct UC-method
        asset_data = CSV.read(asset_file, DataFrame)
        asset_data.unit_commitment_method .= replace.(
            coalesce.(asset_data.unit_commitment_method, ""), # Changes missing values to "", else regex cant match
            r".var-.*" => case
        )
        CSV.write(asset_file, asset_data)

        # Load the csv data
        TulipaIO.read_csv_folder(
            conn,
            input_folder;
            schemas = TulipaEnergyModel.schema_per_table_name,
        )
        
        Run case
        energy_problem = run_scenario(
            conn;
            log_file = "log_file.log",
            output_folder = output_folder,
            model_file_name = "modelnt.lp",
        )
        DBInterface.close!(conn)

        curr_time = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS.sss")
        open(log_file, "a") do io
            println(io, "$curr_time: Finished case: $case_type/$case")
        end
    end
end    
