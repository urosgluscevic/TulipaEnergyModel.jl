using TulipaEnergyModel
using TulipaIO
using DuckDB
using JuMP
using Gurobi
using DataFrames
using CSV

# experiment_inputs_dir = "debugging/experiment-inputs/multiple-countries"
experiment_inputs_dir = "debugging/experiment-inputs/single-country"
experiment_results_dir = "debugging/experiment-results"
# reference_objective = 2338362.08463463

peak_demands = [2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000]
wind_limits = [0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 5000, 6000]
solar_limits = wind_limits ./ 2

# DB connection helper
function input_setup_regret(input_folder)
    rm("experiments_grid.duckdb"; force = true)
    rm("experiments_grid.duckdb.wal"; force = true)

    connection = DBInterface.connect(DuckDB.DB, "experiments_grid.duckdb")

    TulipaIO.read_csv_folder(
        connection,
        input_folder;
        schemas = TulipaEnergyModel.schema_per_table_name,
    )
    return connection
end

regret_baseline_name = "3var-E3"

for i in 1:length(peak_demands)
    for j in 1:length(wind_limits)
        peak_demand = peak_demands[i]
        wind_limit = wind_limits[j]
        solar_limit = solar_limits[j]

        dem = string(peak_demand)
        wind = string(wind_limit)
        sol = string(solar_limit)

        input_folder_baseline = joinpath(pwd(), "$experiment_inputs_dir/$regret_baseline_name")

        asset_milestone_df = DataFrame(CSV.File("$input_folder_baseline/asset-milestone.csv"))
        asset_milestone_df[asset_milestone_df.asset.=="demand", :peak_demand] .= peak_demand

        asset_comm_df = DataFrame(CSV.File("$input_folder_baseline/asset-commission.csv"))
        asset_comm_df[asset_milestone_df.asset.=="OnWind", :investment_limit] .= wind_limit
        asset_comm_df[asset_milestone_df.asset.=="OffWind", :investment_limit] .= wind_limit
        asset_comm_df[asset_milestone_df.asset.=="Solar", :investment_limit] .= solar_limit

        CSV.write("$input_folder_baseline/asset-milestone.csv", asset_milestone_df)
        CSV.write("$input_folder_baseline/asset-commission.csv", asset_comm_df)

        connection = input_setup_regret("$experiment_inputs_dir/$regret_baseline_name")

        energy_problem_E3 = EnergyProblem(connection)
        create_model!(energy_problem_E3)
        solve_model!(energy_problem_E3)

        computed_baseline = energy_problem_E3.objective_value

        save_solution!(energy_problem_E3; compute_duals = false)

        investments_made = get_table(connection, "var_assets_investment")[:, [:asset, :solution]]
        investments_made.solution = round.(investments_made.solution)

        CSV.write(
            "$experiment_results_dir/investment-solutions/$regret_baseline_name-investments-$dem-$wind-$sol.csv",
            DataFrame(investments_made),
        )

        DBInterface.close!(connection)
        rm("experiments_grid.duckdb"; force = true)
        rm("experiments_grid.duckdb.wal"; force = true)

        open(
            "$experiment_results_dir/$regret_baseline_name-obj-$dem-$wind-$sol-DELETE.txt",
            "w",
        ) do io
            println(io, string(computed_baseline))
            return true
        end

        println("bla")
    end
end
