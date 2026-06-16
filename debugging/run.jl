using BenchmarkTools
using TulipaEnergyModel
using TulipaIO
using DuckDB
using JuMP
using Gurobi

experiment_inputs_dir = "debugging/experiment-inputs/single-country"
experiment_results_dir = "debugging/experiment-outputs"

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

io = open("order.txt", "w")
write(io, "aa")
close(io)

# Check if all case studies actually exist
existing_case_studies = readdir(joinpath(pwd(), experiment_inputs_dir))

for case in case_studies_to_run
    if !(case in existing_case_studies)
        throw(
            "The case study with name '$case' does not exist in the $experiment_inputs_dir folder.",
        )
    end
end

conn = DBInterface.connect(DuckDB.DB)
for case in case_studies_to_run
    input_folder = joinpath(pwd(), experiment_inputs_dir, case)

    # Reset database state
    DBInterface.close!(conn)
    conn = DBInterface.connect(DuckDB.DB)

    # Take note of which case we are starting
    io = open("order.txt", "a")
    println(io, input_folder)
    close(io)

    # Load the csv data
    TulipaIO.read_csv_folder(
        conn,
        input_folder;
        schemas = TulipaEnergyModel.schema_per_table_name,
    )

    # Run case
    energy_problem = run_scenario(
        conn;
        log_file = "log_file.log",
        output_folder = joinpath(pwd(), experiment_results_dir, case),
        model_file_name = "modelnt.lp",
    )
end

