open Core
open Benchmark_utils
open Bench_defns
open Lys_interpreter
open Core_bench

let default_display_config =
  Bench.Display_config.create ~ascii_table:true ~show_absolute_ci:true ()

let compile_single_benchmark_program { name; body; persist } eval_ctx typ_ctx =
  print_endline ("... ... compiling benchmark: " ^ name);
  let test =
    Bench.Test.create ~name (fun () ->
        evaluate_from_lexbuf_given_context
          (Interpreter.MultiStep { show_time = true })
          (Lexing.from_string body) eval_ctx typ_ctx)
  in
  if persist then
    let _, new_eval_ctx, new_typ_context =
      evaluate_from_lexbuf_given_context
        (Interpreter.MultiStep { show_time = false })
        (Lexing.from_string body) eval_ctx typ_ctx
    in
    (test, new_eval_ctx, new_typ_context)
  else (test, eval_ctx, typ_ctx)

let compile_base_record ~analysis_configs { base_program_loc; run; benchmarks }
    =
  print_endline
    (Printf.sprintf "---------------------- \n Fetching: %s" base_program_loc);
  let _, eval_ctx, typ_ctx =
    In_channel.with_file base_program_loc ~f:(fun file_ic ->
        evaluate_from_lexbuf_given_context
          (Interpreter.MultiStep { show_time = false })
          (Lexing.from_channel file_ic)
          Interpreter_common.EvaluationContext.empty
          Interpreter_common.TypeConstrContext.empty)
  in
  List.fold benchmarks ~init:([], eval_ctx, typ_ctx)
    ~f:(fun (current_list, eval_ctx, typ_ctx) bm ->
      print_endline ("... compiling benchmark " ^ bm.name);
      compile_single_benchmark_program bm eval_ctx typ_ctx
      |> fun (results, new_eval_ctx, new_typ_ctx) ->
      (results :: current_list, new_eval_ctx, new_typ_ctx))
  |> fun (results, _, _) ->
  ( Bench.Run_config.create ~quota:(Bench.Quota.Num_calls run) (),
    List.map ~f:Bench.Analysis_config.with_error_estimation analysis_configs,
    results )

let compile_bench ?(analysis_configs = Bench.Analysis_config.default) =
  List.map ~f:(compile_base_record ~analysis_configs)

let bench_without_display_or_error ~run_config ~analysis_configs tests =
  tests |> Bench.measure ~run_config
  |> List.map ~f:(Bench.analyze ~analysis_configs)
  |> Or_error.combine_errors

let translate_bench_result_exn (result : Bench.Analysis_result.t) =
  (* Assumes that we are getting ALL the columns
     TODO: Rewrite this so as to support *any* set of columns.
  *)
  let name = Bench.Analysis_result.name result in
  let regressions = Array.to_list (Bench.Analysis_result.regressions result) in
  let get_variable_name = Core_bench_internals.Variable.to_string in
  regressions
  |> List.fold ~init:String.Map.empty ~f:(fun acc reg ->
         let responder = Bench.Analysis_result.Regression.responder reg in
         let r_square =
           Bench.Analysis_result.Regression.r_square reg |> Option.value_exn
         in
         let coefficients =
           Array.to_list (Bench.Analysis_result.Regression.coefficients reg)
         in
         let get_results coeff_result =
           let estimate =
             Bench.Analysis_result.Coefficient.estimate coeff_result
           in
           let lo_hi_option =
             Bench.Analysis_result.Coefficient.ci95 coeff_result
           in
           let lo, hi =
             match lo_hi_option with
             | Some lo_hi ->
                 Bench.Analysis_result.Ci95.ci95_abs_err ~estimate lo_hi
             | None -> (Float.neg_infinity, Float.neg_infinity)
           in
           {
             r_2 = r_square;
             mean = estimate;
             abs_lo_diff = lo;
             abs_hi_diff = hi;
           }
         in
         let get_run_predictor =
           List.find_exn ~f:(fun c ->
               match Bench.Analysis_result.Coefficient.predictor c with
               | `Runs -> true
               | _ -> false)
         in
         let vs_run_results =
           coefficients |> get_run_predictor |> get_results
         in
         String.Map.set acc
           ~key:(get_variable_name responder)
           ~data:vs_run_results)
  |> fun value_map ->
  {
    bench_name = name;
    time_per_run = String.Map.find_exn value_map (get_variable_name `Nanos);
    mWd_per_run =
      String.Map.find_exn value_map (get_variable_name `Minor_allocated);
    mjWd_per_run =
      String.Map.find_exn value_map (get_variable_name `Major_allocated);
    promotions_per_run =
      String.Map.find_exn value_map (get_variable_name `Promoted);
    mGC_per_run =
      String.Map.find_exn value_map (get_variable_name `Minor_collections);
    mjGC_per_run =
      String.Map.find_exn value_map (get_variable_name `Major_collections);
    compactions_per_run =
      String.Map.find_exn value_map (get_variable_name `Compactions);
  }

let translate_bench_results_exn = List.map ~f:translate_bench_result_exn

let run_bench_exn
    (compiled_tests :
      (Bench.Run_config.t * Bench.Analysis_config.t list * Bench.Test.t list)
      list) =
  List.map compiled_tests ~f:(fun (rc, acs, tests) ->
      bench_without_display_or_error ~run_config:rc ~analysis_configs:acs tests
      |> ok_exn)
  |> List.concat
  |> List.rev

let bench_display_exn ?(display_config = default_display_config) bench_list =
  bench_list |> compile_bench |> run_bench_exn |> Bench.display ~display_config

let bench_to_csv_exn bench_list =
  bench_list |> compile_bench |> run_bench_exn |> translate_bench_results_exn
  |> to_csv
