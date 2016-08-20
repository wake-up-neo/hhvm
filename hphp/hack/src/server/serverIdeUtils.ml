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

(*****************************************************************************)
(* Error. *)
(*****************************************************************************)

let canon_set names =
  names
  |> SSet.elements
  |> List.map ~f:NamingGlobal.canon_key
  |> List.fold_left ~f:SSet.add ~init:SSet.empty

let oldify_funs names =
  Naming_heap.FunPosHeap.oldify_batch names;
  Naming_heap.FunCanonHeap.oldify_batch @@ canon_set names;
  Decl_heap.Funs.oldify_batch names;
  ()

let oldify_classes names =
  Naming_heap.TypeIdHeap.oldify_batch names;
  Naming_heap.TypeCanonHeap.oldify_batch @@ canon_set names;
  Decl_class_elements.(
    names |> SSet.elements |> get_for_classes |> oldify_all
  );
  Decl_heap.Classes.oldify_batch names;
  ()

let oldify_typedefs names =
  Naming_heap.TypeIdHeap.oldify_batch names;
  Naming_heap.TypeCanonHeap.oldify_batch @@ canon_set names;
  Decl_heap.Typedefs.oldify_batch names

let oldify_consts names =
  Naming_heap.ConstPosHeap.oldify_batch names;
  Decl_heap.GConsts.oldify_batch names

let oldify_file name =
  Parser_heap.ParserHeap.oldify_batch @@
    Parser_heap.ParserHeap.KeySet.singleton name

let oldify_file_info path file_info =
  oldify_file path;
  let {
    FileInfo.n_funs; n_classes; n_types; n_consts
  } = FileInfo.simplify file_info in
  oldify_funs n_funs;
  oldify_classes n_classes;
  oldify_typedefs n_types;
  oldify_consts n_consts

let revive funs classes typedefs consts file_name =
  Decl_heap.Funs.revive_batch funs;
  Naming_heap.FunPosHeap.revive_batch funs;
  Naming_heap.FunCanonHeap.revive_batch @@ canon_set funs;

  Decl_heap.Classes.revive_batch classes;
  Decl_class_elements.(
    classes |> SSet.elements |> get_for_classes |> revive_all
  );
  Naming_heap.TypeIdHeap.revive_batch classes;
  Naming_heap.TypeCanonHeap.revive_batch @@ canon_set classes;

  Naming_heap.TypeIdHeap.revive_batch typedefs;
  Naming_heap.TypeCanonHeap.revive_batch @@ canon_set typedefs;
  Decl_heap.Typedefs.revive_batch typedefs;

  Naming_heap.ConstPosHeap.revive_batch consts;
  Decl_heap.GConsts.revive_batch consts;

  Parser_heap.ParserHeap.revive_batch @@
    Parser_heap.ParserHeap.KeySet.singleton file_name

let revive_file_info path file_info =
  let {
    FileInfo.n_funs; n_classes; n_types; n_consts
  } = FileInfo.simplify file_info in
  revive n_funs n_classes n_types n_consts path

let path = Relative_path.default
(* This will parse, declare and check all functions and classes in content
 * buffer.
 *
 * Declaring will overwrite definitions on shared heap, so before doing this,
 * the function will also "oldify" them (see functions above and
 * SharedMem.S.oldify_batch) - after working with local content is done,
 * original definitions can (and should) be restored using "revive".
 *)
let declare_and_check content ~f =
  let tcopt = TypecheckerOptions.permissive in
  Autocomplete.auto_complete := false;
  Autocomplete.auto_complete_for_global := "";
  let file_info =
    Errors.ignore_ begin fun () ->
      let {Parser_hack.file_mode = _; comments = _; ast} =
        Parser_hack.program path content
      in
      let funs, classes, typedefs, consts =
        List.fold_left ast ~f:begin fun (funs, classes, typedefs, consts) def ->
        match def with
          | Ast.Fun { Ast.f_name; _ } ->
            f_name::funs, classes, typedefs, consts
          | Ast.Class { Ast.c_name; _ } ->
            funs, c_name::classes, typedefs, consts
          | Ast.Typedef { Ast.t_id; _ } ->
            funs, classes, t_id::typedefs, consts
          | Ast.Constant { Ast.cst_name; _ } ->
            funs, classes, typedefs, cst_name::consts
          | _ -> funs, classes, typedefs, consts
      end ~init:([], [], [], []) in

      let file_info = { FileInfo.empty_t with
        FileInfo.funs; classes; typedefs; consts;
      } in

      oldify_file_info path file_info;

      Parser_heap.ParserHeap.add path ast;
      NamingGlobal.make_env ~funs ~classes ~typedefs ~consts;
      let nast = Naming.program tcopt ast in
      List.iter nast begin function
        | Nast.Fun f -> Decl.fun_decl f
        | Nast.Class c -> Decl.class_decl tcopt c
        | Nast.Typedef t -> Decl.typedef_decl t
        | Nast.Constant cst -> Decl.const_decl cst
      end;
      (* We must run all the declaration steps first to ensure that the
       * typechecking below sees all the new declarations. Lazy decl
       * won't work in this case because we haven't put the new ASTs into
       * the parsing heap. *)
      List.iter nast begin function
        | Nast.Fun f -> Typing.fun_def tcopt f;
        | Nast.Class c -> Typing.class_def tcopt c;
        | Nast.Typedef t -> Typing.typedef_def t;
        | Nast.Constant cst -> Typing.gconst_def cst;
      end;
      file_info
    end
  in
  let result = f path file_info in
  revive_file_info path file_info;
  result

let recheck tcopt filetuple_l =
  SharedMem.invalidate_caches();
  List.iter filetuple_l begin fun (fn, defs) ->
    ignore @@ Typing_check_utils.check_defs tcopt fn defs
  end

let check_file_input tcopt files_info fi =
  match fi with
  | ServerUtils.FileContent content ->
      declare_and_check content ~f:(fun path _ -> path);
  | ServerUtils.FileName fn ->
      let path = Relative_path.create Relative_path.Root fn in
      let () = match Relative_path.Map.get files_info path with
        | Some fileinfo -> recheck tcopt [(path, fileinfo)]
        | None -> () in
      path
