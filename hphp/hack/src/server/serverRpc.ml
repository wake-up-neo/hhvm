(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Core
open Reordered_argument_collections
open ServerEnv
open File_content
open ServerCommandTypes

let handle : type a. genv -> env -> a t -> env * a =
  fun genv env -> function
    | STATUS ->
      HackEventLogger.check_response (Errors.get_error_list env.errorl);
        let el = Errors.get_sorted_error_list env.errorl in
        env, List.map ~f:Errors.to_absolute el
    | COVERAGE_LEVELS fn -> env, ServerColorFile.go env fn
    | INFER_TYPE (fn, line, char) ->
        env, ServerInferType.go env (fn, line, char)
    | AUTOCOMPLETE content ->
        env, ServerAutoComplete.auto_complete env.tcopt content
    | IDENTIFY_FUNCTION (content, line, char) ->
        env, ServerIdentifyFunction.go_absolute content line char env.tcopt
    | OUTLINE content ->
        env, FileOutline.outline content
    | GET_DEFINITION_BY_ID id ->
        env, Option.map (ServerSymbolDefinition.from_symbol_id env.tcopt id)
          SymbolDefinition.to_absolute
    | METHOD_JUMP (class_, find_children) ->
      env, MethodJumps.get_inheritance env.tcopt class_ ~find_children
        env.files_info genv.workers
    | FIND_DEPENDENT_FILES file_list ->
        env, Ai.ServerFindDepFiles.go genv.workers file_list
          (ServerArgs.ai_mode genv.options)
    | FIND_REFS find_refs_action ->
        if ServerArgs.ai_mode genv.options = None then
          env, ServerFindRefs.go find_refs_action genv env
        else
          env, Ai.ServerFindRefs.go find_refs_action genv env
    | IDE_FIND_REFS (content, line, char) ->
        env, ServerFindRefs.go_from_file (content, line, char) genv env
    | IDE_HIGHLIGHT_REFS (content, line, char) ->
        env, ServerHighlightRefs.go (content, line, char) env.tcopt
    | REFACTOR refactor_action ->
        env, ServerRefactor.go refactor_action genv env
    | REMOVE_DEAD_FIXMES codes ->
      HackEventLogger.check_response (Errors.get_error_list env.errorl);
      env, ServerRefactor.get_fixme_patches codes env
    | DUMP_SYMBOL_INFO file_list ->
        env, SymbolInfoService.go genv.workers file_list env
    | DUMP_AI_INFO file_list ->
        env, Ai.InfoService.go Typing_check_utils.check_defs genv.workers
          file_list (ServerArgs.ai_mode genv.options) env.tcopt
    | ARGUMENT_INFO (contents, line, col) ->
        env, ServerArgumentInfo.go contents line col
    | SEARCH (query, type_) -> env, ServerSearch.go genv.workers query type_
    | COVERAGE_COUNTS path -> env, ServerCoverageMetric.go path genv env
    | LINT fnl -> env, ServerLint.go genv env fnl
    | LINT_ALL code -> env, ServerLint.lint_all genv env code
    | CREATE_CHECKPOINT x -> env, ServerCheckpoint.create_checkpoint x
    | RETRIEVE_CHECKPOINT x -> env, ServerCheckpoint.retrieve_checkpoint x
    | DELETE_CHECKPOINT x -> env, ServerCheckpoint.delete_checkpoint x
    | STATS -> env, Stats.get_stats ()
    | KILL -> env, ()
    | FIND_LVAR_REFS (content, line, char) ->
        env, ServerFindLocals.go content line char
    | FORMAT (content, from, to_) ->
        env, ServerFormat.go content from to_
    | TRACE_AI action ->
        env, Ai.TraceService.go action Typing_check_utils.check_defs
           (ServerArgs.ai_mode genv.options) env.tcopt
    | AI_QUERY json ->
        env, Ai.QueryService.go json
    | ECHO_FOR_TEST msg ->
        env, msg
    | OPEN_FILE path ->
        let path = Relative_path.(concat Root path) in
        let content =
          try Sys_utils.cat (Relative_path.to_absolute path) with _ -> "" in
        let fc = of_content ~content in
        let edited_files = Relative_path.Map.add env.edited_files path fc in
        let files_to_check = Relative_path.Set.add env.files_to_check path in
        let last_command_time = Unix.gettimeofday () in
        let new_env = { env with
          edited_files; files_to_check; last_command_time;
        } in
        new_env, ()
    | CLOSE_FILE path ->
        let path = Relative_path.(concat Root path) in
        let edited_files = Relative_path.Map.remove env.edited_files path in
        let files_to_check =
          Relative_path.Set.remove env.files_to_check path in
        let last_command_time = Unix.gettimeofday () in
        let new_env = { env with
          edited_files; files_to_check; last_command_time
        } in
        new_env, ()
    | EDIT_FILE (path, edits) ->
        let path = Relative_path.(concat Root path) in
        let fc = try Relative_path.Map.find_unsafe env.edited_files path
        with Not_found ->
          let content =
            try Sys_utils.cat (Relative_path.to_absolute path) with _ -> "" in
          of_content ~content in
        let edited_fc = edit_file fc edits in
        let edited_files =
          Relative_path.Map.add env.edited_files path edited_fc in
        let files_to_check =
          Relative_path.Set.add env.files_to_check path in
        let last_command_time = Unix.gettimeofday () in
        let new_env = { env with
          edited_files; files_to_check; last_command_time
        } in
        new_env, ()
    | IDE_AUTOCOMPLETE (path, pos) ->
        let path = Relative_path.(concat Root path) in
        let fc = try
        Relative_path.Map.find_unsafe env.edited_files path
        with Not_found ->
        let content =
          try Sys_utils.cat (Relative_path.to_absolute path) with _ -> "" in
        of_content content in
        let edits = [{range = Some {st = pos; ed = pos}; text = "AUTO332"}] in
        let edited_fc = edit_file fc edits in
        let content = get_content edited_fc in
        env, ServerAutoComplete.auto_complete env.tcopt content
    | IDE_HIGHLIGHT_REF (path, {line; column}) ->
        let relative_path = Relative_path.(concat Root path) in
        let path = Relative_path.path_of_prefix Relative_path.Root ^ path in
        begin match Relative_path.Map.mem env.edited_files relative_path with
        | true ->
          begin match SMap.exists env.symbols_cache (fun p _ -> p = path) with
          | true ->
            env, ServerHighlightRefs.go_from_file (path, line, column) env
          | false ->
            let content = File_content.get_content @@
              Relative_path.Map.find_unsafe env.edited_files relative_path in
            let res = ServerIdentifyFunction.get_full_occurrence_pair content in
            let symbols_cache_ = SMap.add env.symbols_cache path res in
            let env = {env with symbols_cache = symbols_cache_} in
            env, ServerHighlightRefs.go_from_file (path, line, column) env
          end
        | false ->
          let content = try Sys_utils.cat path with _ -> "" in
          env, ServerHighlightRefs.go (content, line, column) env.tcopt
        end
    | IDE_IDENTIFY_FUNCTION (path, {line; column}) ->
        let relative_path = Relative_path.(concat Root path) in
        let path = Relative_path.path_of_prefix Relative_path.Root ^ path in
        begin match Relative_path.Map.mem env.edited_files relative_path with
        | true ->
          begin match SMap.exists env.symbols_cache (fun p _ -> p = path) with
          | true ->
            env, ServerIdentifyFunction.go_from_file (path, line, column) env
          | false ->
            let content = File_content.get_content @@
              Relative_path.Map.find_unsafe env.edited_files relative_path in
            let res = ServerIdentifyFunction.get_full_occurrence_pair content in
            let symbols_cache_ = SMap.add env.symbols_cache path res in
            let env = {env with symbols_cache = symbols_cache_} in
            env, ServerIdentifyFunction.go_from_file (path, line, column) env
          end
        | false ->
          let content = try Sys_utils.cat path with _ -> "" in
          env, ServerIdentifyFunction.go_absolute content line column env.tcopt
        end
    | DISCONNECT ->
        let new_env = {env with
        persistent_client = None;
        edited_files = Relative_path.Map.empty;
        diag_subscribe = None;
        symbols_cache = SMap.empty} in
        new_env, ()
    | SUBSCRIBE_DIAGNOSTIC id ->
        let new_env = { env with
          diag_subscribe = Some (Diagnostic_subscription.of_id id)
        } in
        new_env, ()
    | UNSUBSCRIBE_DIAGNOSTIC id ->
        let diag_subscribe = match env.diag_subscribe with
          | Some x when Diagnostic_subscription.get_id x = id -> None
          | x -> x
        in
        let new_env = { env with diag_subscribe } in
        new_env, ()

let to_string : type a. a t -> _ = function
  | STATUS -> "STATUS"
  | INFER_TYPE _ -> "INFER_TYPE"
  | COVERAGE_LEVELS _ -> "COVERAGE_LEVELS"
  | AUTOCOMPLETE _ -> "AUTOCOMPLETE"
  | IDENTIFY_FUNCTION _ -> "IDENTIFY_FUNCTION"
  | OUTLINE _ -> "OUTLINE"
  | METHOD_JUMP _ -> "METHOD_JUMP"
  | FIND_DEPENDENT_FILES _ -> "FIND_DEPENDENT_FILES"
  | FIND_REFS _ -> "FIND_REFS"
  | REFACTOR _ -> "REFACTOR"
  | REMOVE_DEAD_FIXMES _ -> "REMOVE_DEAD_FIXMES"
  | DUMP_SYMBOL_INFO _ -> "DUMP_SYMBOL_INFO"
  | DUMP_AI_INFO _ -> "DUMP_AI_INFO"
  | ARGUMENT_INFO _ -> "ARGUMENT_INFO"
  | SEARCH _ -> "SEARCH"
  | COVERAGE_COUNTS _ -> "COVERAGE_COUNTS"
  | LINT _ -> "LINT"
  | LINT_ALL _ -> "LINT_ALL"
  | CREATE_CHECKPOINT _ -> "CREATE_CHECKPOINT"
  | RETRIEVE_CHECKPOINT _ -> "RETRIEVE_CHECKPOINT"
  | DELETE_CHECKPOINT _ -> "DELETE_CHECKPOINT"
  | STATS -> "STATS"
  | KILL -> "KILL"
  | FIND_LVAR_REFS _ -> "FIND_LVAR_REFS"
  | FORMAT _ -> "FORMAT"
  | TRACE_AI _ -> "TRACE_AI"
  | IDE_FIND_REFS _ -> "IDE_FIND_REFS"
  | GET_DEFINITION_BY_ID _ -> "GET_DEFINITION_BY_ID"
  | IDE_HIGHLIGHT_REFS _ -> "IDE_HIGHLIGHT_REFS"
  | AI_QUERY _ -> "AI_QUERY"
  | ECHO_FOR_TEST _ -> "ECHO_FOR_TEST"
  | OPEN_FILE _ -> "OPEN_FILE"
  | CLOSE_FILE _ -> "CLOSE_FILE"
  | EDIT_FILE _ -> "EDIT_FILE"
  | IDE_AUTOCOMPLETE _ -> "IDE_AUTOCOMPLETE"
  | IDE_HIGHLIGHT_REF _ -> "IDE_HIGHLIGHT_REF"
  | IDE_IDENTIFY_FUNCTION _ -> "IDE_IDENTIFY_FUNCTION"
  | DISCONNECT -> "DISCONNECT"
  | SUBSCRIBE_DIAGNOSTIC _ -> "SUBSCRIBE_DIAGNOSTIC"
  | UNSUBSCRIBE_DIAGNOSTIC _ -> "UNSUBSCRIBE_DIAGNOSTIC"
