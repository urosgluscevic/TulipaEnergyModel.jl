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

cases = [
    "1var-0",
    "1var-E1C",
    # "1var-E1CT",
    "1var-E2C",
    # "1var-E2CT",
    # "2var-0C",
    # "2var-0T",
    # "2var-E1",
    # "2var-E2",
    # "3var-0C",
    "3var-0T",
    # "3var-0N",
    "3var-E1",
    # "3var-E2",
]
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

function regret_calculation(
    case,
    reference_objective,
    dem,
    wind,
    sol,
    peak_demand,
    wind_limit,
    solar_limit,
)
    input_folder = joinpath(pwd(), "$experiment_inputs_dir/$case")

    connection = input_setup_regret(input_folder)

    energy_problem = EnergyProblem(connection)
    create_model!(energy_problem)
    solve_model!(energy_problem)

    save_solution!(energy_problem; compute_duals = false)

    investments_made = get_table(connection, "var_assets_investment")[:, [:asset, :solution]]
    investments_made.solution = round.(investments_made.solution)

    CSV.write(
        "$experiment_results_dir/investment-solutions/$case-investments-$dem-$wind-$sol.csv",
        DataFrame(investments_made),
    )

    indices = DuckDB.query(
        connection,
        "SELECT
            var.id,
            var.asset,
            obj.weight_for_asset_investment_discount
                * obj.investment_cost
                * obj.capacity
                AS cost,
        FROM var_assets_investment AS var
        LEFT JOIN t_objective_assets as obj
            ON var.asset = obj.asset
            AND var.milestone_year = obj.milestone_year
        ORDER BY var.id
        ",
    )

    investments_and_costs = leftjoin(DataFrame(indices), investments_made; on = :asset)

    assets_investment_cost = sum(investments_and_costs.cost .* investments_and_costs.solution)

    input_folder_baseline = joinpath(pwd(), "$experiment_inputs_dir/regret_baseline")

    asset_both_df = DataFrame(CSV.File("$input_folder_baseline/asset-both.csv"))

    asset_both_df = leftjoin(asset_both_df, investments_made; on = :asset)
    asset_both_df.initial_units = asset_both_df.solution
    asset_both_df = select!(asset_both_df, Not(:solution))

    asset_both_df[asset_both_df.asset.=="ens", :initial_units] .= 1
    asset_both_df[asset_both_df.asset.=="demand", :initial_units] .= 0

    CSV.write("$input_folder_baseline/asset-both.csv", asset_both_df)

    asset_milestone_df = DataFrame(CSV.File("$input_folder_baseline/asset-milestone.csv"))
    asset_milestone_df[asset_milestone_df.asset.=="demand", :peak_demand] .= peak_demand

    asset_comm_df = DataFrame(CSV.File("$input_folder_baseline/asset-commission.csv"))
    asset_comm_df[asset_milestone_df.asset.=="OnWind", :investment_limit] .= wind_limit
    asset_comm_df[asset_milestone_df.asset.=="OffWind", :investment_limit] .= wind_limit
    asset_comm_df[asset_milestone_df.asset.=="Solar", :investment_limit] .= solar_limit

    CSV.write("$input_folder_baseline/asset-milestone.csv", asset_milestone_df)
    CSV.write("$input_folder_baseline/asset-commission.csv", asset_comm_df)

    DBInterface.close!(connection)
    rm("experiments_grid.duckdb"; force = true)
    rm("experiments_grid.duckdb.wal"; force = true)

    connection = input_setup_regret(input_folder_baseline)

    energy_problem_baseline = EnergyProblem(connection)

    create_model!(energy_problem_baseline)

    solve_model!(energy_problem_baseline)

    REGRET =
        (energy_problem_baseline.objective_value + assets_investment_cost) - reference_objective

    DBInterface.close!(connection)
    rm("experiments_grid.duckdb"; force = true)
    rm("experiments_grid.duckdb.wal"; force = true)

    GC.gc()

    return [REGRET, assets_investment_cost, energy_problem_baseline.objective_value]
end

function write_results_regret(metrics_dict, dem, wind, sol)
    open("$experiment_results_dir/regret$dem-$wind-$sol.csv", "w") do io
        println(io, "case,regret,investment_cost,operation_cost")

        for (key, value) in metrics_dict
            to_print = "$key," * join(value, ",")
            println(io, to_print)
        end
    end
end

# metrics_dict = Dict()

# connection = input_setup_regret("$experiment_inputs_dir/3var-E2")

# energy_problem_E3 = EnergyProblem(connection)
# create_model!(energy_problem_E3)
# solve_model!(energy_problem_E3)

# computed_baseline = energy_problem_E3.objective_value

# # println(computed_baseline - reference_objective)

# save_solution!(energy_problem_E3)

# investments_made = get_table(connection, "var_assets_investment")[:, [:asset, :solution]]
# investments_made.solution = round.(investments_made.solution)

# CSV.write(
#     "$experiment_results_dir/investment-solutions/3var-E2-investments.csv",
#     DataFrame(investments_made),
# )

# metrics_dict["3var-E2"] = [computed_baseline, 0, 0]

regret_baseline_name = "3var-E2"

for i in 1:length(peak_demands)
    for j in 1:length(wind_limits)
        peak_demand = peak_demands[i]
        wind_limit = wind_limits[j]
        solar_limit = solar_limits[j]

        dem = string(peak_demand)
        wind = string(wind_limit)
        sol = string(solar_limit)

        metrics_dict = Dict()

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

        # println(computed_baseline - reference_objective)

        save_solution!(energy_problem_E3; compute_duals = false)

        investments_made = get_table(connection, "var_assets_investment")[:, [:asset, :solution]]
        investments_made.solution = round.(investments_made.solution)

        CSV.write(
            "$experiment_results_dir/investment-solutions/$regret_baseline_name-investments-$dem-$wind-$sol.csv",
            DataFrame(investments_made),
        )

        metrics_dict[regret_baseline_name] = [computed_baseline, 0, 0]

        for case in cases
            input_folder_baseline = joinpath(pwd(), "$experiment_inputs_dir/$case")

            asset_milestone_df = DataFrame(CSV.File("$input_folder_baseline/asset-milestone.csv"))
            asset_milestone_df[asset_milestone_df.asset.=="demand", :peak_demand] .= peak_demand

            asset_comm_df = DataFrame(CSV.File("$input_folder_baseline/asset-commission.csv"))
            asset_comm_df[asset_milestone_df.asset.=="OnWind", :investment_limit] .= wind_limit
            asset_comm_df[asset_milestone_df.asset.=="OffWind", :investment_limit] .= wind_limit
            asset_comm_df[asset_milestone_df.asset.=="Solar", :investment_limit] .= solar_limit

            CSV.write("$input_folder_baseline/asset-milestone.csv", asset_milestone_df)
            CSV.write("$input_folder_baseline/asset-commission.csv", asset_comm_df)

            metrics_dict[case] = regret_calculation(
                case,
                computed_baseline,
                dem,
                wind,
                sol,
                peak_demand,
                wind_limit,
                solar_limit,
            )
        end

        write_results_regret(metrics_dict, dem, wind, sol)
    end
end

# write_results_regret(metrics_dict)
