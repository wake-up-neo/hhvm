open ServerCommandTypes

let debug_describe_t : type a. a t -> string = function
  | STATUS                     -> "STATUS"
  | INFER_TYPE               _ -> "INFER_TYPE"
  | COVERAGE_LEVELS          _ -> "COVERAGE_LEVELS"
  | AUTOCOMPLETE             _ -> "AUTOCOMPLETE"
  | IDENTIFY_FUNCTION        _ -> "IDENTIFY_FUNCTION"
  | GET_DEFINITION_BY_ID     _ -> "GET_DEFINITION_BY_ID"
  | METHOD_JUMP              _ -> "METHOD_JUMP"
  | FIND_DEPENDENT_FILES     _ -> "FIND_DEPENDENT_FILES"
  | FIND_REFS                _ -> "FIND_REFS"
  | IDE_FIND_REFS            _ -> "IDE_FIND_REFS"
  | IDE_HIGHLIGHT_REFS       _ -> "IDE_HIGHLIGHT_REFS"
  | REFACTOR                 _ -> "REFACTOR"
  | DUMP_SYMBOL_INFO         _ -> "DUMP_SYMBOL_INFO"
  | DUMP_AI_INFO             _ -> "DUMP_AI_INFO"
  | REMOVE_DEAD_FIXMES       _ -> "REMOVE_DEAD_FIXMES"
  | IGNORE_FIXMES            _ -> "IGNORE_FIXMES"
  | SEARCH                   _ -> "SEARCH"
  | COVERAGE_COUNTS          _ -> "COVERAGE_COUNTS"
  | LINT                     _ -> "LINT"
  | LINT_ALL                 _ -> "LINT_ALL"
  | CREATE_CHECKPOINT        _ -> "CREATE_CHECKPOINT"
  | RETRIEVE_CHECKPOINT      _ -> "RETRIEVE_CHECKPOINT"
  | DELETE_CHECKPOINT        _ -> "DELETE_CHECKPOINT"
  | STATS                      -> "STATS"
  | KILL                       -> "KILL"
  | FORMAT                   _ -> "FORMAT"
  | IDE_FORMAT               _ -> "IDE_FORMAT"
  | TRACE_AI                 _ -> "TRACE_AI"
  | AI_QUERY                 _ -> "AI_QUERY"
  | DUMP_FULL_FIDELITY_PARSE _ -> "DUMP_FULL_FIDELITY_PARSE"
  | OPEN_FILE                _ -> "OPEN_FILE"
  | CLOSE_FILE               _ -> "CLOSE_FILE"
  | EDIT_FILE                _ -> "EDIT_FILE"
  | IDE_AUTOCOMPLETE         _ -> "IDE_AUTOCOMPLETE"
  | DISCONNECT                 -> "DISCONNECT"
  | SUBSCRIBE_DIAGNOSTIC     _ -> "SUBSCRIBE_DIAGNOSTIC"
  | UNSUBSCRIBE_DIAGNOSTIC   _ -> "UNSUBSCRIBE_DIAGNOSTIC"
  | OUTLINE                  _ -> "OUTLINE"

let debug_describe_cmd : type a. a command -> string = function
  | Rpc rpc -> debug_describe_t rpc
  | Stream _ -> "Stream"
  | Debug -> "Debug"
