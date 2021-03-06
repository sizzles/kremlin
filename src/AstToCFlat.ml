(** Going from CStar to CFlat *)

module CF = CFlat
module K = Constant
module LidMap = Idents.LidMap
module StringMap = Map.Make(String)

(** Sizes *)

open CFlat.Sizes
open Ast
open PrintAst.Ops

(** We know how much space is needed to represent each C* type. *)
let size_of (t: typ): size =
  match t with
  | TInt w ->
      size_of_width w
  | TArray _ | TBuf _ ->
      I32
  | TBool | TUnit ->
      I32
  | TZ | TBound _ | TTuple _ | TArrow _ | TQualified _ | TApp _ ->
      invalid_arg ("size_of: this case should've been eliminated: " ^ show_typ t)
  | TAnonymous _ | TAny ->
      failwith "not implemented"

let max s1 s2 =
  match s1, s2 with
  | I32, I32 -> I32
  | _ -> I64

let size_of_array_elt (t: typ): array_size =
  match t with
  | TInt w ->
      array_size_of_width w
  | TArray _ | TBuf _ ->
      A32
  | TBool | TUnit ->
      failwith "todo: packed arrays of bools/units?!"
  | TZ | TBound _ | TTuple _ | TArrow _ | TQualified _ | TApp _ ->
      invalid_arg ("size_of: this case should've been eliminated: " ^ show_typ t)
  | TAnonymous _ | TAny ->
      failwith "not implemented"


(** Environments.
 *
 * Variable declarations are visited in infix order; this order is used for
 * numbering the corresponding Cflat local declarations. Wasm will later on take
 * care of register allocation. *)
type env = {
  binders: int list;
  enums: int LidMap.t;
    (** Enumeration constants are assigned a distinct integer. *)
  structs: layout LidMap.t;
    (** Pre-computed layouts for struct types. *)
}

and layout = {
  size: int;
    (** In bytes *)
  fields: (string * offset) list;
    (** Any struct must be laid out on a word boundary (64-bit). Then, fields
     * can be always accessed using the most efficient offset computation. *)
}

and offset =
  array_size * int

let empty = {
  binders = [];
  enums = LidMap.empty;
  structs = LidMap.empty;
}

(** Layouts.
 *
 * Filling in the initial environment with struct layout, and an assignment of
 * enum constants to integers. *)

let struct_size env lid =
  (LidMap.find lid env.structs).size

let align array_size pos =
  (* Align on array size boundary *)
  let b = bytes_in array_size in
  let pos =
    if pos mod b = 0 then
      pos
    else
      pos + (bytes_in array_size - (pos mod bytes_in array_size))
  in
  pos, (array_size, pos/b)

let layout env fields: layout =
  let fields, size =
    List.fold_left (fun (layout, n_bytes) (fname, (t, _mut)) ->
      (* We've laid out things up to [n_bytes] in the struct; these are recorded
       * in [layout]. *)
      let fname = Option.must fname in
      match t with
      | TQualified lid ->
          if not (LidMap.mem lid env.structs) then
            Warnings.fatal_error "Cannot layout sub-field of type %a" ptyp t;
          let n_bytes, ofs = align A64 n_bytes in
          (fname, ofs) :: layout, n_bytes + struct_size env lid
      | t ->
          let s = size_of_array_elt t in
          let n_bytes, ofs = align s n_bytes in
          (fname, ofs) :: layout, n_bytes + bytes_in s
    ) ([], 0) fields
  in
  let fields = List.rev fields in
  { fields; size }

let populate env files =
  (* Assign integers to enums *)
  let env = List.fold_left (fun env (_, decls) ->
    List.fold_left (fun env decl ->
      match decl with
      | DType (_, _, Enum idents) ->
          KList.fold_lefti (fun i env ident ->
            { env with enums = LidMap.add ident i env.enums }
          ) env idents
      | _ ->
          env
    ) env decls
  ) env files in
  (* Compute the layouts *)
  let env = List.fold_left (fun env (_, decls) ->
    List.fold_left (fun env decl ->
      match decl with
      | DType (lid, _, Flat fields) ->
          (* Need to pass in the layout of previous structs *)
          let l = layout env fields in
          { env with structs = LidMap.add lid l env.structs }
      | _ ->
          env
    ) env decls
  ) env files in
  env

let debug_env { structs; enums; _ } =
  KPrint.bprintf "Struct layout:\n";
  LidMap.iter (fun lid { size; fields } ->
    KPrint.bprintf "%a (size=%d, %d fields)\n" plid lid size (List.length fields);
    List.iter (fun (f, (array_size, ofs)) ->
      KPrint.bprintf "  %s: %s %d = %d\n" f (string_of_array_size array_size)
        ofs (bytes_in array_size * ofs)
    ) fields
  ) structs;
  KPrint.bprintf "Enum constant assignments:\n";
  LidMap.iter (fun lid d ->
    KPrint.bprintf "  %a = %d\n" plid lid d
  ) enums

(** When translating, we carry around the list of locals allocated so far within
 * the current function body, along with an environment (for the De Bruijn indices);
 * the i-th element in [binders] is De Bruijn variable [i]. When calling, say,
 * [mk_expr], the locals are returned (they monotonically grow) and the
 * environment is discarded.
 *
 * Note that this list is kept in reverse. *)
type locals = size list

(** An index in the locals table *)
type var = int

(** Bind a new Cflat variable. We always carry around all the allocated locals,
 * so they next local slot is just [List.length locals]. *)
let extend (env: env) (binder: binder) (locals: locals): locals * var * env =
  let v = List.length locals in
  size_of binder.typ :: locals,
  v,
  { env with
    binders = List.length locals :: env.binders;
  }

(** Find a variable in the environment. *)
let find env v =
  List.nth env.binders v

(** A helpful combinators. *)
let fold (f: locals -> 'a -> locals * 'b) (locals: locals) (xs: 'a list): locals * 'b list =
  let locals, ys = List.fold_left (fun (locals, acc) x ->
    let locals, y = f locals x in
    locals, y :: acc
  ) (locals, []) xs in
  locals, List.rev ys

let assert_var = function
  | CF.Var i -> i
  | _ -> invalid_arg "assert_var"

let assert_buf = function
  | TArray (t, _) | TBuf t -> t
  | _ -> invalid_arg "assert_buf"

(** The actual translation. Note that the environment is dropped, but that the
 * locals are chained through (state-passing style). *)
let rec mk_expr (env: env) (locals: locals) (e: expr): locals * CF.expr =
  match e.node with
  | EBound v ->
      locals, CF.Var (find env v)

  | EOpen _ ->
      invalid_arg "mk_expr (EOpen)"

  | EApp ({ node = EOp (o, w); _ }, es) ->
      let locals, es = fold (mk_expr env) locals es in
      locals, CF.CallOp ((w, o), es)

  | EApp ({ node = EQualified ident; _ }, es) ->
      let locals, es = fold (mk_expr env) locals es in
      locals, CF.CallFunc (Idents.string_of_lident ident, es)

  | EApp _ ->
      failwith "unsupported application"

  | EConstant (w, lit) ->
      locals, CF.Constant (w, lit)

  | EEnum v ->
      locals, CF.Constant (K.UInt32, string_of_int (LidMap.find v env.enums))

  | EQualified v ->
      locals, CF.GetGlobal (Idents.string_of_lident v)

  | EBufCreate (l, e_init, e_len) ->
      assert (e_init.node = EAny);
      let locals, e_len = mk_expr env locals e_len in
      locals, CF.BufCreate (l, e_len, size_of_array_elt (assert_buf e.typ))

  | EBufCreateL _ | EBufBlit _ | EBufFill _ ->
      invalid_arg "this should've been desugared in Simplify.wasm"

  | EBufRead (e1, e2) ->
      let s = size_of_array_elt (assert_buf e1.typ) in
      let locals, e1 = mk_expr env locals e1 in
      let locals, e2 = mk_expr env locals e2 in
      locals, CF.BufRead (e1, e2, s)

  | EBufSub (e1, e2) ->
      let s = size_of_array_elt (assert_buf e1.typ) in
      let locals, e1 = mk_expr env locals e1 in
      let locals, e2 = mk_expr env locals e2 in
      locals, CF.BufSub (e1, e2, s)

  | EBufWrite (e1, e2, e3) ->
      let s = size_of_array_elt (assert_buf e1.typ) in
      let locals, e1 = mk_expr env locals e1 in
      let locals, e2 = mk_expr env locals e2 in
      let locals, e3 = mk_expr env locals e3 in
      locals, CF.BufWrite (e1, e2, e3, s)

  | EBool b ->
      locals, CF.Constant (K.Bool, if b then "1" else "0")

  | ECast (e, TInt wt) ->
      let wf = match e.typ with TInt wf -> wf | _ -> failwith "non-int cast" in
      let locals, e = mk_expr env locals e in
      locals, CF.Cast (e, wf, wt)

  | ECast _ ->
      failwith "unsupported cast"

  | EAny ->
      failwith "not supported EAny"

  | ELet (b, e1, e2) ->
      if e1.node = EAny then
        let locals, _, env = extend env b locals in
        let locals, e2 = mk_expr env locals e2 in
        locals, e2
      else
        let locals, e1 = mk_expr env locals e1 in
        let locals, v, env = extend env b locals in
        let locals, e2 = mk_expr env locals e2 in
        locals, CF.Sequence [
          CF.Assign (v, e1);
          e2
        ]

  | EIfThenElse (e1, e2, e3) ->
      let s2 = size_of e2.typ in
      let s3 = size_of e3.typ in
      assert (s2 = s3);
      let locals, e1 = mk_expr env locals e1 in
      let locals, e2 = mk_expr env locals e2 in
      let locals, e3 = mk_expr env locals e3 in
      locals, CF.IfThenElse (e1, e2, e3, s2)

  | EAbort _ ->
      locals, CF.Abort

  | EPushFrame ->
      locals, CF.PushFrame

  | EPopFrame ->
      locals, CF.PopFrame

  | ETuple _ | EMatch _ | ECons _ ->
      invalid_arg "should've been desugared before"

  | EComment (_, e, _) ->
      mk_expr env locals e

  | ESequence es ->
      let locals, es = fold (mk_expr env) locals es in
      locals, CF.Sequence es

  | EAssign (e1, e2) ->
      begin match e1.typ, e2.node with
      | TArray (_typ, _sizexp), (EBufCreate _ | EBufCreateL _) ->
          invalid_arg "this should've been desugared by Simplify.Wasm into let + blit"
      | _ ->
          let locals, e1 = mk_expr env locals e1 in
          let locals, e2 = mk_expr env locals e2 in
          locals, CF.Assign (assert_var e1, e2)
      end

  | ESwitch (e, branches) ->
      let locals, e = mk_expr env locals e in
      let locals, branches = fold (fun locals (i, e) ->
        let i = CF.Constant (K.UInt32, string_of_int (LidMap.find i env.enums)) in
        let locals, e = mk_expr env locals e in
        locals, (i, e)
      ) locals branches in
      locals, CF.Switch (e, branches)

  | EFor (b, e1, e2, e3, e4) ->
      let locals, e1 = mk_expr env locals e1 in
      let locals, v, env = extend env b locals in
      let locals, e2 = mk_expr env locals e2 in
      let locals, e3 = mk_expr env locals e3 in
      let locals, e4 = mk_expr env locals e4 in
      locals, CF.Sequence [
        CF.Assign (v, e1);
        CF.While (e2, CF.Sequence [ e4; e3 ])]

  | EWhile (e1, e2) ->
      let locals, e1 = mk_expr env locals e1 in
      let locals, e2 = mk_expr env locals e2 in
      locals, CF.While (e1, e2)

  | EString s ->
      locals, CF.StringLiteral s

  | EUnit ->
      locals, CF.Constant (K.UInt32, "0")

  | EOp _ ->
      failwith "standalone application"

  | EFlat _ | EField _ ->
      failwith "todo eflat"

  | EReturn _ ->
      invalid_arg "return shouldnt've been inserted"

  | EFun _ ->
      invalid_arg "funs should've been substituted"

  | EAddrOf _ ->
      invalid_arg "adress-of should've been resolved"

  | EIgnore _ ->
      failwith "TODO"


(* See digression for [dup32] in CFlatToWasm *)
let scratch_locals =
  [ I64; I64; I32; I32 ]

let mk_decl env (d: decl): CF.decl option =
  match d with
  | DFunction (_, flags, n, ret, name, args, body) ->
      assert (n = 0);
      let public = not (List.exists ((=) Common.Private) flags) in
      let locals, env = List.fold_left (fun (locals, env) b ->
        let locals, _, env = extend env b locals in
        locals, env
      ) ([], env) args in
      let locals = List.rev_append scratch_locals locals in
      let locals, body = mk_expr env locals body in
      let ret = [ size_of ret ] in
      let locals = List.rev locals in
      let args, locals = KList.split (List.length args) locals in
      let name = Idents.string_of_lident name in
      Some CF.(Function { name; args; ret; locals; body; public })

  | DType _ ->
      (* Not translating type declarations. *)
      None

  | DGlobal (flags, name, typ, body) ->
      let public = not (List.exists ((=) Common.Private) flags) in
      let size = size_of typ in
      let locals, body = mk_expr env [] body in
      let name = Idents.string_of_lident name in
      if locals = [] then
        Some (CF.Global (name, size, body, public))
      else
        failwith "global generates let-bindings"

  | _ ->
      failwith ("not implemented (decl); got: " ^ show_decl d)

let mk_module env (name, decls) =
  name, KList.filter_map (fun d ->
    try
      mk_decl env d
    with e ->
      (* Remove when everything starts working *)
      KPrint.beprintf "[C*ToC-] Couldn't translate %a:\n%s\n%s\n"
        PrintAst.plid (lid_of_decl d) (Printexc.to_string e)
        (Printexc.get_backtrace ());
      None
  ) decls

let mk_files files =
  let env = populate empty files in
  if Options.debug "cflat" then
    debug_env env;
  List.map (mk_module env) files
