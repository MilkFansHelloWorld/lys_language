open Core
open Lys_parsing
open Lys_typing
open Lys_ast
open Lys_interpreter

let loop time_exec lexbuf context typ_context () =
  lexbuf |> Lex_and_parse.parse_program |> Ast.Program.of_past
  |> Typecore.type_check_program
       ~obj_ctx:(Interpreter.EvaluationContext.to_typing_obj_context context)
       ~type_ctx:
         (Interpreter.TypeConstrContext.to_typeconstrtypingcontext typ_context)
  |> ok_exn |> Ast.TypedProgram.populate_index |> ok_exn
  |> Interpreter.evaluate_top_level_defns ~top_level_context:context
       ~type_constr_context:typ_context ~time_exec
  |> ok_exn

let read_line () =
  Out_channel.(flush stdout);
  In_channel.(input_line_exn stdin)

let print_exec_result res continue evaluation_context typ_context =
  match res with
  | Error e ->
      print_endline "ERROR";
      print_endline (Error.to_string_hum e)
  | Ok (res, new_context, new_typ_context) ->
      (List.iter res ~f:(fun res ->
           print_endline
             (Interpreter.TopLevelEvaluationResult.get_str_output res);
           print_endline "");
       (*Now just stop when we have to stop*)
       let last_res_opt = List.last res in
       match last_res_opt with
       | None -> ()
       | Some last_res -> (
           match last_res with
           | Interpreter.TopLevelEvaluationResult.Directive
               (Ast.Directive.Quit, _) ->
               continue := false
           | _ -> ()));
      evaluation_context := new_context;
      typ_context := new_typ_context

let main_loop time_exec pre_load_opt () =
  let continue = ref true in
  let accumulated_program = ref "" in
  let evaluation_context = ref Interpreter.EvaluationContext.empty in
  let typ_context = ref Interpreter.TypeConstrContext.empty in
  match pre_load_opt with
  | None -> ()
  | Some pre_load_file ->
      print_endline ("PRELOADING FILE " ^ pre_load_file);
      In_channel.with_file pre_load_file ~f:(fun channel ->
          let res =
            Or_error.try_with
              (loop time_exec
                 (channel |> Lexing.from_channel)
                 !evaluation_context !typ_context)
          in
          print_endline "-------------------";
          print_exec_result res continue evaluation_context typ_context);
      print_endline "-------------------";
      print_string "# ";
      while !continue do
        let line = read_line () in
        accumulated_program := !accumulated_program ^ line;
        if String.is_suffix line ~suffix:";;" then (
          (*execute*)
          let res =
            Or_error.try_with
              (loop time_exec
                 (!accumulated_program |> Lexing.from_string)
                 !evaluation_context !typ_context)
          in
          print_endline "-------------------";
          print_exec_result res continue evaluation_context typ_context;
          accumulated_program := "";
          print_endline "-------------------";
          print_string "# ")
        else ()
      done

let () =
  Command.basic_spec ~summary:"Lys REPL.\n Use flags -time to time the execution of each expression, and -withfile [file] to preload a file."
    Command.Spec.(
      empty
      +> flag "time" no_arg ~doc:"Time execution of each expression."
      +> flag "withfile" (optional Command.Spec.string) ~doc:"Pre-load file")
    main_loop
  |> Command_unix.run
