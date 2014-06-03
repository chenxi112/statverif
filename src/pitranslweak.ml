(*************************************************************
 *                                                           *
 *  Cryptographic protocol verifier                          *
 *                                                           *
 *  Bruno Blanchet, Xavier Allamigeon, and Vincent Cheval    *
 *                                                           *
 *  Copyright (C) INRIA, LIENS, MPII 2000-2013               *
 *                                                           *
 *************************************************************)

(*

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details (in file LICENSE).

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

*)
open Parsing_helper
open Types
open Pitypes

module FunMap = struct
    include Funmap.FunMap
    let for_all f m = Funmap.FunMap.fold (fun k v x -> x && (f k v)) m true
end

(*********************************************
          Function For Phases
**********************************************)

(* Find the minimum phase in which choice is used *)

let rec has_choice = function
    Var _ -> false
  | FunApp(f,l) ->
      (f.f_cat == Choice) || (List.exists has_choice l)

let rec has_choice_pat = function
    PatVar _ -> false
  | PatTuple(_,l) -> List.exists has_choice_pat l
  | PatEqual t -> has_choice t

let min_choice_phase = ref max_int

let rec find_min_choice_phase current_phase process =
  let set() =
    if current_phase < !min_choice_phase then
      min_choice_phase := current_phase
  in
  match process with
    Nil -> ()
  | Par(p,q) ->
      find_min_choice_phase current_phase p;
      find_min_choice_phase current_phase q
  | Repl (p,_) ->
      find_min_choice_phase current_phase p
  | Restr(n,p,_) ->
      find_min_choice_phase current_phase p
  | Test(t,p,q,_) ->
      if has_choice t then set();
      find_min_choice_phase current_phase p;
      find_min_choice_phase current_phase q
  | Input(tc,pat,p,_) ->
      if (has_choice tc) || (has_choice_pat pat) then set();
      find_min_choice_phase current_phase p
  | Output(tc,t,p,_) ->
      if has_choice tc || has_choice t then set();
      find_min_choice_phase current_phase p

  | Let(pat,t,p,q,_) ->
      if (has_choice t) || (has_choice_pat pat) then set();
      find_min_choice_phase current_phase p;
      find_min_choice_phase current_phase q
  | LetFilter(vlist,f,p,q,_) ->
      user_error "Predicates are currently incompatible with proofs of equivalences.\n"
  | Event(t,p,_) ->
      if has_choice t then set();
      find_min_choice_phase current_phase p
  | Insert(t,p,_) ->
      if has_choice t then set();
      find_min_choice_phase current_phase p
  | Get(pat,t,p,q,_) ->
      if (has_choice t) || (has_choice_pat pat) then set();
      find_min_choice_phase current_phase p;
      find_min_choice_phase current_phase q
  | Phase(n,p,_) ->
      find_min_choice_phase n p
  | Lock(_,p,_) | Unlock(_,p,_) | Open(_,p,_) ->
      find_min_choice_phase current_phase p
  | ReadAs(sp,p,_) ->
      if (List.exists (fun (_,p) -> has_choice_pat p) sp) then set();
      find_min_choice_phase current_phase p
  | Assign(st,p,_) ->
      if (List.exists (fun (_,t) -> has_choice t) st) then set();
      find_min_choice_phase current_phase p

(*********************************************
          Function For Rules
**********************************************)

(** Indicate the number of rules created *)
let nrule = ref 0

(** List of the rules created *)
let red_rules = ref ([] : reduction list)

let mergelr = function
  | Pred({p_info = [AttackerBin(i,_)  | MessBin(i,_) | TableBin(i)
                  | InputPBin(i) | OutputPBin(i)]} as p, terms)
  when i < !min_choice_phase ->
    let terms_left, terms_right = Misc.bisect terms in
    List.iter2 Terms.unify terms_left terms_right;
    let mono_pred = match p.p_info with
      | [AttackerBin(i,t)] -> Attacker(i,t)
      | [MessBin(i,t)] -> Mess(i,t)
      | [TableBin(i)] -> Table(i)
      | [InputPBin(i)] -> InputP(i)
      | [OutputPBin(i)] -> OutputP(i)
    in Pred(Param.get_pred mono_pred, terms_left)
  | x -> x

let rec nb_rule_total = ref 0


let add_rule hyp concl constra tags =
  if !min_choice_phase > 0 then
    begin
      assert (!Terms.current_bound_vars == []);
      try
	let hyp' = List.map mergelr hyp in
	let concl' = mergelr concl in
	let hyp'' = List.map Terms.copy_fact2 hyp' in
	let concl'' = Terms.copy_fact2 concl' in
	let constra'' = List.map Terms.copy_constra2 constra in
	let tags'' =
	  match tags with
	    ProcessRule(hsl, nl) -> ProcessRule(hsl, List.map Terms.copy_term2 nl)
	  | x -> x
	in
	Terms.cleanup();

        let constra''' = TermsEq.simplify_constra_list (concl''::hyp'') constra'' in
        let rule = (hyp'', concl'', Rule (!nrule, tags'', hyp'', concl'', constra'''), constra''') in
	red_rules := rule :: !red_rules;
	incr nrule;
      with
        | Terms.Unify ->  Terms.cleanup ()
        | TermsEq.FalseConstraint -> ()
    end
  else
    begin
      try
        let constra' = TermsEq.simplify_constra_list (concl::hyp) constra in
      	let rule = (hyp, concl, Rule (!nrule, tags, hyp, concl, constra'), constra') in
      	red_rules := rule :: !red_rules;
      	incr nrule;
      with
      	TermsEq.FalseConstraint -> ()
    end

(*********************************************
           Preliminary functions
**********************************************)

type cell_state =
  { locked      : bool;
    valid       : bool;
    left_value  : term;
    right_value : term
  }

type transl_state =
  { hypothesis : fact list; (* Current hypotheses of the rule *)
    constra : constraints list list; (* Current constraints of the rule *)

    name_params : term list; (* List of parameters of names *)
    name_params_types : typet list;
    name_params_meaning : string list;
    repl_count  : int; (* Counter for replication *)

    input_pred  : predicate;
    output_pred : predicate;
    cur_phase   : int; (* Current phase *)
    cur_cells   : cell_state FunMap.t; (* Current cell states *)
    hyp_tags : hypspec list
  }

let display_transl_state cur_state =
   Printf.printf "\n--- Display current state ---\n";
   Printf.printf "\nHypothesis:\n";
   Display.Text.display_list (Display.Text.WithLinks.fact) " ; " cur_state.hypothesis;
   Printf.printf "\nConstraint:\n";
   Display.Text.WithLinks.constra_list cur_state.constra;
   Printf.printf "\nName params:\n";
   Display.Text.display_term_list cur_state.name_params;
   Printf.printf "\n"

(* Tools *)

let get_type_from_pattern = function
  | PatVar(v) -> v.btype
  | PatTuple(f,_) -> snd f.f_type
  | PatEqual(t) -> Terms.get_term_type t

(* State manipulation. *)

(* Invalidate unlocked cells. *)
let invalidate_cells ts =
  { ts with cur_cells = FunMap.map
    (fun cell ->
      if cell.locked then cell
      else {cell with valid = false})
    ts.cur_cells
  }

(* Return term for left/right state. *)
let x_state getx cell_states =
  FunApp(Param.state_fun,
    List.fold_right (fun (r, _) l ->
      (getx (FunMap.find (r, "") cell_states))::l)
      !Param.cells [])
let left_state = x_state (fun cell -> cell.left_value)
let right_state = x_state (fun cell -> cell.right_value)

(* Create fresh variables for invalidated cells. *)
let update_cells ts =
  if FunMap.for_all (fun _ cell -> cell.valid) ts.cur_cells then ts else
  let old_cells = ts.cur_cells in
  let new_cells = FunMap.mapi (fun ({f_name=s; f_type=(_,t)},_) cell ->
    if cell.valid then cell else
    { cell with
      valid = true;
      left_value = Var(Terms.new_var s t);
      right_value = Var(Terms.new_var s t) }
  ) old_cells in
  { ts with
    cur_cells = new_cells;
    hypothesis = (Pred(Param.get_pred (SeqBin(ts.cur_phase)),
                       [left_state old_cells; left_state new_cells;
                        right_state old_cells; right_state new_cells]))
                 :: ts.hypothesis;
    hyp_tags = SequenceTag :: ts.hyp_tags }

(* Return initial cell states. *)
let initial_state () =
  List.fold_left (fun result ({f_type=_,t} as cell, opt_init) ->
    let left, right =
      match opt_init with
        | Some init ->
          (Terms.auto_cleanup (fun () -> Terms.copy_term2 init),
           Terms.auto_cleanup (fun () -> Terms.copy_term2 init))
        | None ->
          (Var (Terms.new_var cell.f_name t),
           Var (Terms.new_var cell.f_name t))
    in
    FunMap.add (cell, "")
      { locked = false;
        valid = true;
        left_value = left;
        right_value = right }
      result
  ) FunMap.empty !Param.cells

(* Return map of new variables, one for each cell * side. *)
let new_state () =
  List.fold_left (fun result ({f_type=_,t} as cell,_) ->
    let xl = Terms.new_var cell.f_name t in
    let xr = Terms.new_var cell.f_name t in
    FunMap.add (cell, "")
      { locked = false;
        valid = true;
        left_value = Var xl;
        right_value = Var xr }
    result) FunMap.empty !Param.cells

let new_state_format () =
  FFunApp(Param.state_fun,
    List.map (fun ({f_type=_,t} as cell,_) ->
      FAny(Terms.new_var cell.f_name t)) !Param.cells)
let new_state_formatv () =
  FFunApp(Param.state_fun,
    List.map (fun ({f_type=_,t} as cell,_) ->
      FVar(Terms.new_var cell.f_name t)) !Param.cells)

(* Creation of fact of attacker', mess' and table. *)

let att_fact s phase t1 t2 =
  Pred(Param.get_pred (AttackerBin(phase, Terms.get_term_type t1)),
    [left_state s; t1; right_state s; t2])

let mess_fact s phase tc1 tm1 tc2 tm2 =
  Pred(Param.get_pred (MessBin(phase, Terms.get_term_type tm1)),
    [left_state s; tc1; tm1; right_state s; tc2; tm2])

let table_fact phase t1 t2 =
  Pred(Param.get_pred (TableBin(phase)), [t1;t2])

(* Outputting a rule *)

let output_rule cur_state out_fact =
  Terms.auto_cleanup (fun _ ->
    (* Apply the unification *)
    let hyp = List.map Terms.copy_fact2 cur_state.hypothesis in
    let concl = Terms.copy_fact2 out_fact in
    let constra = List.map Terms.copy_constra2 cur_state.constra in
    let name_params = List.map Terms.copy_term2 cur_state.name_params in
    Terms.cleanup();
    begin
      try
        let constra2 = (TermsEq.simplify_constra_list (concl::hyp) constra) in
        add_rule hyp concl constra2 (ProcessRule(cur_state.hyp_tags, name_params))
      with TermsEq.FalseConstraint ->
         ()
    end
      )


(*********************************************
               Translate Terms
**********************************************)

(* [transl_term : (transl_state -> Types.terms -> Types.terms -> unit) -> transl_state -> Types.term -> unit
[transl_term f cur t] represent the translation of [t] in the current state [cur]. The two patterns that [f]
accepts as argument reprensent the result of the evalution
on open term on the left part and right part of [t].

Invariant : All variables should be linked with two closed terms when applied on the translation (due to closed processes)
*)
let rec transl_term next_f cur_state term = match term with
  | Var v ->
      begin
        match  v.link with
          | TLink (FunApp(_,[t1;t2])) -> next_f cur_state t1 t2
          | _ -> internal_error "unexpected link in translate_term (1)"
      end
  | FunApp(f,args) ->
      let transl_red red_rules =
      	transl_term_list (fun cur_state1 term_list1 term_list2 ->
      	  if cur_state.cur_phase < !min_choice_phase then
      	    List.iter (fun red_rule ->
      	      let (left_list1, right1, side_c1) = Terms.auto_cleanup (fun _ -> Terms.copy_red red_rule) in
      	      let (left_list2, right2, side_c2) = Terms.auto_cleanup (fun _ -> Terms.copy_red red_rule) in
      	
      	      Terms.auto_cleanup (fun _ ->
		try
		  List.iter2 Terms.unify term_list1 left_list1;
		  List.iter2 Terms.unify term_list2 left_list2;
      	          let cur_state2 =
      	          { cur_state1 with
	            constra =
	              (List.map (fun (t1,t2) -> [Neq(t1,t2)]) side_c1) @
	              (List.map (fun (t1,t2) -> [Neq(t1,t2)]) side_c2) @ cur_state1.constra
		  } in
		
		  ignore (TermsEq.check_constraint_list cur_state2.constra);	
      	          next_f cur_state2 right1 right2
                with Terms.Unify -> ()
	      )
	    ) red_rules
	  else
	    List.iter (fun red_rule1 ->
	      List.iter (fun red_rule2 ->
	        (* Fresh rewrite rules *)
	        let (left_list1, right1, side_c1) = Terms.auto_cleanup (fun _ -> Terms.copy_red red_rule1) in
	        let (left_list2, right2, side_c2) = Terms.auto_cleanup (fun _ -> Terms.copy_red red_rule2) in

	        Terms.auto_cleanup (fun _ ->
		  try
		    List.iter2 Terms.unify term_list1 left_list1;
		    List.iter2 Terms.unify term_list2 left_list2;
	            let cur_state2 =
	            { cur_state1 with
	              constra =
	                (List.map (fun (t1,t2) -> [Neq(t1,t2)]) side_c1) @
	                (List.map (fun (t1,t2) -> [Neq(t1,t2)]) side_c2) @ cur_state1.constra
		    } in
		
		    ignore (TermsEq.check_constraint_list cur_state2.constra);
	            next_f cur_state2 right1 right2
		  with Terms.Unify -> ()
	        )
	      ) red_rules
	    ) red_rules
	) cur_state args
      in

      match f.f_cat with
      	| Name n ->
      	    (* Parameters of names are now equals on the left and right side *)
      	    begin
      	      match n.prev_inputs with
      	        | Some (name_term) -> next_f cur_state name_term name_term
      	        | _ -> internal_error "unexpected prev_inputs in transl_term"
      	    end
      	| Tuple | Eq _ | Red _ ->
      	    transl_red (Terms.red_rules_fun f)
	| Choice ->
	    begin
	      match args with
	        | [t1;t2] ->
		  transl_term (fun cur_state1 t11 t12 ->
		    transl_term (fun cur_state2 t21 t22 ->
		      next_f cur_state2 t11 t22
		    ) cur_state1 t2
		  ) cur_state t1
		| _ -> Parsing_helper.internal_error "Choice should have two arguments"
	    end
	| Failure -> next_f cur_state (FunApp(f,[]))  (FunApp(f,[]))
	
	| _ ->
	    Parsing_helper.internal_error "function symbols of these categories should not appear in input terms (pitranslweak)"

(* next_f takes a state and two lists of patterns as parameter *)
and transl_term_list next_f cur_state = function
    [] -> next_f cur_state [] []
  | (a::l) ->
      transl_term (fun cur_state1 p1 p2 ->
	transl_term_list (fun cur_state2 patlist1 patlist2 ->
	  next_f cur_state2 (p1::patlist1) (p2::patlist2)) cur_state1 l) cur_state a
	
let transl_term_incl_destructor next_f cur_state occ term =
  let may_have_several_patterns = Reduction_helper.transl_check_several_patterns occ term in
  transl_term (fun cur_state1 term1 term2 ->
    if may_have_several_patterns
    then
      let type_t = Terms.get_term_type term1 in
      next_f { cur_state1 with
          name_params = FunApp(Param.choice_fun type_t,[term1;term2])::cur_state1.name_params;
          name_params_types = type_t (* this type may not be accurate when types are ignored
					(a type conversion function may have been removed); we
					don't use it since it is not associated to a variable *)
                                     :: cur_state1.name_params_types;
          name_params_meaning = "" :: cur_state1.name_params_meaning
        } term1 term2
    else
      next_f cur_state1 term1 term2
  ) cur_state term


(*********************************************
              Translate Patterns
**********************************************)

let rec transl_pat next_f cur_state pattern =
  match pattern with
  | PatVar b ->
      let x_left = Var (Terms.copy_var b)
      and x_right = Var (Terms.copy_var b) in
      b.link <- TLink (FunApp(Param.choice_fun b.btype, [x_left; x_right]));
      next_f cur_state (Var b) [b];
      b.link <- NoLink
  | PatTuple(fsymb,pat_list) ->
      transl_pat_list (fun cur_state2 term_list binder_list ->
        next_f cur_state2 (FunApp(fsymb,term_list)) binder_list
      ) cur_state pat_list
  | PatEqual t -> next_f cur_state t []

and transl_pat_list next_f cur_state = function
  | [] -> next_f cur_state [] []
  | pat::q ->
      transl_pat (fun cur_state2 term binders2 ->
        transl_pat_list (fun cur_state3 term_list binders3  ->
          next_f cur_state3 (term::term_list) (binders2@binders3)
        ) cur_state2 q
      ) cur_state pat

(*********************************************
        Equation of success or failure
**********************************************)

exception Failure_Unify

(* Unify term t with a message variable.
   Raises Unify in case t is fail. *)

let unify_var t =
  let x = Terms.new_var_def (Terms.get_term_type t) in
  Terms.unify t x

(* Unify term t with fail *)

let unify_fail t =
  let fail = Terms.get_fail_term (Terms.get_term_type t) in
  Terms.unify fail t

let transl_both_side_succeed nextf cur_state list_left list_right  =
  Terms.auto_cleanup (fun _ ->
    try
      List.iter unify_var list_left;
      List.iter unify_var list_right;
      nextf cur_state
    with Terms.Unify -> ()
  )

let transl_both_side_fail nextf cur_state list_left list_right  =
  List.iter (fun t_left ->
    List.iter (fun t_right ->
      Terms.auto_cleanup (fun _ ->
        try
          unify_fail t_left;
          unify_fail t_right;
          nextf cur_state
        with Terms.Unify -> ()
            )
      ) list_right;
  ) list_left


let transl_one_side_fails nextf cur_state list_failure list_success  =
  List.iter (fun t ->
    Terms.auto_cleanup (fun _ ->
      try
	List.iter unify_var list_success;
      	unify_fail t;
	nextf cur_state
      with Terms.Unify -> ()
	  )
  ) list_failure

(**********************************************************
        Generation of pattern with universal variables
***********************************************************)

let generate_pattern_with_uni_var binders_list term_pat_left term_pat_right =
  let var_pat_l,var_pat_r =
    List.split (
      List.map (fun b ->
        match b.link with
          | TLink(FunApp(_,[Var(x1);Var(x2)])) -> (x1,x2)
          | _ -> internal_error "unexpected link in translate_term (2)"
      ) binders_list
    ) in

  (* TO DO this code may cause internal errors in the presence of patterns
     let (b, =g(b)) = .... when b gets unified with a term that is not a variable.
     However, such patterns are forbidden, so this is not a problem. *)

  let new_var_pat_l = List.map (fun v ->
    match Terms.follow_link (fun b -> Var b) (Var v) with
      |Var v' -> v'
      |_ -> internal_error "unexpected term in translate_process (3)") var_pat_l

  and new_var_pat_r = List.map (fun v ->
    match Terms.follow_link (fun b -> Var b) (Var v) with
      |Var v' -> v'
      |_ -> internal_error "unexpected term in translate_process (4)") var_pat_r in

  let new_term_pat_left = Terms.follow_link (fun b -> Var b) term_pat_left
  and new_term_pat_right = Terms.follow_link (fun b -> Var b) term_pat_right in

  let gen_pat_l = Terms.auto_cleanup (fun _ -> Terms.generalize_vars_in new_var_pat_l new_term_pat_left)
  and gen_pat_r = Terms.auto_cleanup (fun _ -> Terms.generalize_vars_in new_var_pat_r new_term_pat_right) in

  gen_pat_l,gen_pat_r

(*********************************************
              Translate Process
**********************************************)

let all_types () =
  if !Param.ignore_types then [Param.any_type]
  else !Param.all_types

let unify_cells cur_state side =
  List.iter2 (fun (cell, _) term ->
      Terms.unify term
        (side (FunMap.find (cell, "") cur_state.cur_cells))
    )

let rec transl_process cur_state process =

  (* DEBUG mode *)

  (*
  Printf.printf "\n\n**********************\n\n";
  Display.Text.display_process_occ "" process;
  display_transl_state cur_state;
  flush_all ();
  *)

  match process with
  | Nil -> ()
  | Par(proc1,proc2) ->
      let cur_state = invalidate_cells cur_state in
      transl_process cur_state proc1;
      transl_process cur_state proc2
  | Repl(proc,occ) ->
      (* Always introduce session identifiers ! *)
      let var = Terms.new_var "@sid" Param.sid_type in
      let cur_state' =
        {
          (invalidate_cells cur_state) with
          repl_count = cur_state.repl_count + 1;
          name_params = (Var var)::cur_state.name_params;
          name_params_types = Param.sid_type ::cur_state.name_params_types;
          name_params_meaning = (Printf.sprintf "!%d" (cur_state.repl_count + 1))::cur_state.name_params_meaning;
          hyp_tags = (ReplTag(occ, List.length cur_state.name_params)) :: cur_state.hyp_tags
        } in
      transl_process cur_state' proc

  | Restr(name,proc,occ) ->
      begin
        match name.f_cat with
          | Name r ->
              let name_prev_type = cur_state.name_params_types in
              if Terms.eq_lists (fst name.f_type) Param.tmp_type
              then
                begin
                  name.f_type <- name_prev_type, snd name.f_type;
                  r.prev_inputs_meaning <- cur_state.name_params_meaning
                end
  	      else if !Param.ignore_types then
		begin
	          (* When we ignore types, the types of the arguments may vary,
                     only the number of arguments is preserved. *)
		  if List.length (fst name.f_type) != List.length name_prev_type then
		    internal_error ("Name " ^ name.f_name ^ " has bad arity")
		end
	      else
		begin
		  if not (Terms.eq_lists (fst name.f_type) name_prev_type) then
  		    internal_error ("Name " ^ name.f_name ^ " has bad type")
		end;
  	      if List.length r.prev_inputs_meaning <> List.length cur_state.name_params
  	      then internal_error "prev_inputs_meaning and name_params should have the same size";
		
  	      r.prev_inputs <- Some (FunApp(name, cur_state.name_params));
  	      transl_process cur_state proc;
  	      r.prev_inputs <- None

          | _ -> internal_error "A restriction should have a name as parameter"
      end

  | Test(term1,proc_then,proc_else,occ) ->
      (* This case is equivalent to :
         Let z = equals(condition,True) in proc_then else proc_else *)

      if proc_else == Nil then
        (* We optimize the case q == Nil.
	   In this case, the adversary cannot distinguish the situation
	   in which t fails from the situation in which t is false. *)
	transl_term_incl_destructor (fun cur_state1 term1_left term1_right ->
            (* Branch THEN (both sides are true) *)
            Terms.auto_cleanup (fun _ ->
	      try
		Terms.unify term1_left Terms.true_term;
		Terms.unify term1_right Terms.true_term;
		transl_process { cur_state1 with
		                 hyp_tags = (TestTag occ)::cur_state1.hyp_tags
			       } proc_then;
              with Terms.Unify -> ()
            );

            (* BAD (Left is true / Right is false) *)
            Terms.auto_cleanup (fun _ ->
	      try
		Terms.unify term1_left Terms.true_term;
		unify_var term1_right;
                output_rule { cur_state1 with
		              constra = [Neq(term1_right,Terms.true_term)]::cur_state1.constra;
		              hyp_tags = (TestUnifTag2 occ)::cur_state1.hyp_tags
                            } (Pred(Param.bad_pred, []));
              with Terms.Unify -> ()
            );

            (* BAD (Left is true / Right fails) *)
            Terms.auto_cleanup (fun _ ->
	      try
		Terms.unify term1_left Terms.true_term;
		unify_fail term1_right;
                output_rule { cur_state1 with
		              hyp_tags = (TestUnifTag2 occ)::cur_state1.hyp_tags
                            } (Pred(Param.bad_pred, []));
              with Terms.Unify -> ()
            );

            (* BAD (Left is false / Right is true) *)
            Terms.auto_cleanup (fun _ ->
	      try
		Terms.unify term1_right Terms.true_term;
		unify_var term1_left;
                output_rule { cur_state1 with
                              constra = [Neq(term1_left,Terms.true_term)]::cur_state1.constra;
                              hyp_tags = (TestUnifTag2 occ)::cur_state1.hyp_tags
                            } (Pred(Param.bad_pred, []));
              with Terms.Unify -> ()
            );

            (* BAD (Left fails / Right is true) *)
            Terms.auto_cleanup (fun _ ->
	      try
		Terms.unify term1_right Terms.true_term;
		unify_fail term1_left;
                output_rule { cur_state1 with
                              hyp_tags = (TestUnifTag2 occ)::cur_state1.hyp_tags
                            } (Pred(Param.bad_pred, []));
              with Terms.Unify -> ()
            )

        ) cur_state (OTest(occ)) term1
      else
	transl_term_incl_destructor (fun cur_state1 term1_left term1_right ->
          (* Case both sides succeed *)
          transl_both_side_succeed (fun cur_state2 ->
            (* Branch THEN *)
            Terms.auto_cleanup (fun _ ->
	      try
		Terms.unify term1_left Terms.true_term;
		Terms.unify term1_right Terms.true_term;
		transl_process { cur_state2 with
		                 hyp_tags = (TestTag occ)::cur_state2.hyp_tags
			       } proc_then;
              with Terms.Unify -> ()
            );

            (* Branch ELSE *)
            transl_process { cur_state2 with
              constra = [Neq(term1_left,Terms.true_term)]::[Neq(term1_right,Terms.true_term)]::cur_state2.constra;
              hyp_tags = (TestTag occ)::cur_state2.hyp_tags
            } proc_else;

            (* BAD (Left ok / Right ko) *)
            Terms.auto_cleanup (fun _ ->
	      try
		Terms.unify term1_left Terms.true_term;
                output_rule { cur_state2 with
		              constra = [Neq(term1_right,Terms.true_term)]::cur_state2.constra;
		              hyp_tags = (TestUnifTag2 occ)::cur_state2.hyp_tags
                            } (Pred(Param.bad_pred, []));
              with Terms.Unify -> ()
            );

            (* BAD (Left ko / Right ok) *)
            Terms.auto_cleanup (fun _ ->
	      try
		Terms.unify term1_right Terms.true_term;
                output_rule { cur_state2 with
                              constra = [Neq(term1_left,Terms.true_term)]::cur_state2.constra;
                              hyp_tags = (TestUnifTag2 occ)::cur_state2.hyp_tags
                            } (Pred(Param.bad_pred, []));
              with Terms.Unify -> ()
            )
          ) cur_state1 [term1_left] [term1_right];

          (* Case left side succeed and right side fail *)
          transl_one_side_fails (fun cur_state2 ->
            (* BAD *)
            output_rule { cur_state2 with
              hyp_tags = TestUnifTag2(occ)::cur_state2.hyp_tags
            } (Pred(Param.bad_pred, []));
          ) cur_state1 [term1_right] [term1_left];

          (* Case right side succeed and left side fail *)
          transl_one_side_fails (fun cur_state2 ->
            (* BAD *)
            output_rule { cur_state2 with
              hyp_tags = TestUnifTag2(occ)::cur_state2.hyp_tags
            } (Pred(Param.bad_pred, []));
          ) cur_state1 [term1_left] [term1_right]
        ) cur_state (OTest(occ)) term1

  | Let(pat,term,proc_then,proc_else, occ) ->

      transl_term_incl_destructor (fun cur_state1 term_left term_right ->
        transl_pat (fun cur_state2 term_pattern binders_list ->
          transl_term (fun cur_state3 term_pat_left term_pat_right ->
            (* Generate the pattern with universal_variable *)
            let gen_pat_l, gen_pat_r = generate_pattern_with_uni_var binders_list term_pat_left term_pat_right in

            (* Case both sides succeed *)
            transl_both_side_succeed (fun cur_state4 ->
              (* Branch THEN *)
              Terms.auto_cleanup (fun _ ->
		try
		  Terms.unify term_left term_pat_left;
		  Terms.unify term_right term_pat_right;
		  transl_process { cur_state4 with
                    hyp_tags = (LetTag occ)::cur_state4.hyp_tags
                  } proc_then;
                with Terms.Unify -> ()
              );

              (* Branch ELSE *)
              transl_process { cur_state4 with
                constra = [Neq(gen_pat_l,term_left)]::[Neq(gen_pat_r,term_right)]::cur_state4.constra;
                hyp_tags = (LetTag occ)::cur_state4.hyp_tags
              } proc_else;

              (* BAD (Left ok / Right ko) *)
              Terms.auto_cleanup (fun _ ->
		try
		  Terms.unify term_left term_pat_left;
		  output_rule { cur_state4 with
                    constra = [Neq(gen_pat_r,term_right)]::cur_state4.constra;
                    hyp_tags = TestUnifTag2(occ)::cur_state4.hyp_tags
                  } (Pred(Param.bad_pred, []))
                with Terms.Unify -> ()
              );

              (* BAD (Left ko / Right ok) *)
              Terms.auto_cleanup (fun _ ->
		try
		  Terms.unify term_right term_pat_right;
                  output_rule { cur_state4 with
                    constra = [Neq(gen_pat_l,term_left)]::cur_state4.constra;
                    hyp_tags = TestUnifTag2(occ)::cur_state4.hyp_tags
                  } (Pred(Param.bad_pred, []));
                with Terms.Unify -> ()
              )
            ) cur_state3 [term_pat_left;term_left] [term_pat_right;term_right];

            (* Case both sides fail *)
	    transl_both_side_fail (fun cur_state4 ->
              transl_process { cur_state4 with
                hyp_tags = (LetTag occ)::cur_state4.hyp_tags
              } proc_else
            ) cur_state3 [term_pat_left;term_left] [term_pat_right;term_right];

            (* Case left side succeed and right side fail *)
            transl_one_side_fails (fun cur_state4 ->
              (* Branch ELSE *)
              transl_process { cur_state4 with
                constra = [Neq(gen_pat_l,term_left)]::cur_state4.constra;
                hyp_tags = (LetTag occ)::cur_state4.hyp_tags
              } proc_else;

              (* BAD (Left ok) *)
              Terms.auto_cleanup (fun _ ->
		try
                  Terms.unify term_left term_pat_left;
                  output_rule { cur_state4 with
                    hyp_tags = TestUnifTag2(occ)::cur_state4.hyp_tags
                  } (Pred(Param.bad_pred, []))
                with Terms.Unify -> ()
              )
            ) cur_state3 [term_pat_right;term_right] [term_pat_left;term_left];

            (* Case right side succeed and left side fail *)
            transl_one_side_fails (fun cur_state4 ->
              (* Branch ELSE *)
              transl_process { cur_state4 with
                constra = [Neq(gen_pat_r,term_right)]::cur_state4.constra;
                hyp_tags = (LetTag occ)::cur_state4.hyp_tags
              } proc_else;

              (* BAD (Left ko) *)
              Terms.auto_cleanup (fun _ ->
		try
		  Terms.unify term_right term_pat_right;
		  output_rule { cur_state4 with
                    hyp_tags = TestUnifTag2(occ)::cur_state4.hyp_tags
                  } (Pred(Param.bad_pred, []))
                with Terms.Unify -> ()
              )
            ) cur_state3 [term_pat_left;term_left] [term_pat_right;term_right]
          ) cur_state2 term_pattern
        ) cur_state1 pat
      ) cur_state (OLet(occ)) term

  | Input(tc,pat,proc,occ) ->
      begin
        let cur_state = update_cells (invalidate_cells cur_state) in
	match tc with
        | FunApp({ f_cat = Name _; f_private = false },_) when !Param.active_attacker ->
            transl_pat (fun cur_state1 term_pattern binders ->
              transl_term (fun cur_state2 term_pat_left term_pat_right ->
                (* Generate the basic pattern variables *)
                let x_right = Terms.new_var_def (Terms.get_term_type term_pat_right)
                and x_left = Terms.new_var_def (Terms.get_term_type term_pat_left) in

                (* Generate the pattern with universal_variable *)
                let gen_pat_l, gen_pat_r = generate_pattern_with_uni_var binders term_pat_left term_pat_right in

                (* Case both sides succeed *)
                transl_both_side_succeed (fun cur_state3 ->

                  (* Pattern satisfied in both sides *)
                  transl_process { cur_state3 with
                    name_params = (List.map
                      (fun b -> match b.link with
                         | TLink t -> t
                         | _ ->internal_error "unexpected link in translate_term (3)"
                      ) binders) @ cur_state3.name_params;
                    name_params_types = (List.map (fun b -> b.btype) binders)@cur_state3.name_params_types;
                    name_params_meaning = (List.map (fun b -> b.sname) binders)@cur_state3.name_params_meaning;
                    hypothesis = (att_fact cur_state3.cur_cells cur_state.cur_phase term_pat_left term_pat_right) :: cur_state3.hypothesis;
                    hyp_tags = (InputTag occ)::cur_state3.hyp_tags
                  } proc;

                  (* Pattern satisfied only on left side *)
                  output_rule { cur_state3 with
                    constra = [Neq(gen_pat_r,x_right)]::cur_state3.constra;
                    hypothesis = (att_fact cur_state3.cur_cells cur_state3.cur_phase term_pat_left x_right) :: cur_state3.hypothesis;
                    hyp_tags = TestUnifTag2(occ)::(InputTag occ)::cur_state3.hyp_tags
                  } (Pred(Param.bad_pred, []));

                  (* Pattern satisfied only on right side *)
                  output_rule { cur_state3 with
                    constra = [Neq(gen_pat_l,x_left)]::cur_state3.constra;
                    hypothesis = (att_fact cur_state3.cur_cells cur_state3.cur_phase x_left term_pat_right) :: cur_state3.hypothesis;
                    hyp_tags = TestUnifTag2(occ)::(InputTag occ)::cur_state3.hyp_tags
                  } (Pred(Param.bad_pred, []))

                ) cur_state2 [term_pat_left] [term_pat_right];

                (* Case left side succeed and right side fail *)
                transl_one_side_fails (fun cur_state3 ->
                  output_rule { cur_state3 with
                    hypothesis = (att_fact cur_state3.cur_cells cur_state3.cur_phase term_pat_left x_right) :: cur_state3.hypothesis;
                    hyp_tags = (TestUnifTag2 occ)::(InputTag occ)::cur_state3.hyp_tags
                  } (Pred(Param.bad_pred, []))
                ) cur_state2 [term_pat_right] [term_pat_left];

                (* Case right side succeed and left side fail *)
                transl_one_side_fails (fun cur_state3 ->
                  output_rule { cur_state3 with
                    hypothesis = (att_fact cur_state3.cur_cells cur_state3.cur_phase x_left term_pat_right) :: cur_state3.hypothesis;
                    hyp_tags = (TestUnifTag2 occ)::(InputTag occ)::cur_state3.hyp_tags
                  } (Pred(Param.bad_pred, []))
                ) cur_state2 [term_pat_left] [term_pat_right]
              ) cur_state1 term_pattern
            ) cur_state pat

        | _ ->
          transl_term_incl_destructor (fun cur_state1 channel_left channel_right ->
            (* Case both channel succeed *)
            transl_both_side_succeed (fun cur_state2 ->
              transl_pat (fun cur_state3 term_pattern binders ->
                transl_term (fun cur_state4 term_pat_left term_pat_right ->
                  (* Generate the basic pattern variables *)
                  let x_right = Terms.new_var_def (Terms.get_term_type term_pat_right)
                  and x_left = Terms.new_var_def (Terms.get_term_type term_pat_left) in

                  (* Generate the pattern with universal_variable *)
                  let gen_pat_l, gen_pat_r = generate_pattern_with_uni_var binders term_pat_left term_pat_right in

                  (* Case where both pattern succeed *)

                  transl_both_side_succeed (fun cur_state5 ->
                    let cur_state6 = { cur_state5 with
                      name_params = (List.map
                        (fun b -> match b.link with
                           | TLink t -> t
                           | _ ->internal_error "unexpected link in translate_term (4)"
                      ) binders) @ cur_state5.name_params;
                      name_params_types = (List.map (fun b -> b.btype) binders)@cur_state5.name_params_types;
                      name_params_meaning = (List.map (fun b -> b.sname) binders)@cur_state5.name_params_meaning;

                    } in

                    (* Pattern satisfied in both sides *)
                    transl_process { cur_state6 with
                      hypothesis = (mess_fact cur_state.cur_cells cur_state.cur_phase channel_left term_pat_left channel_right term_pat_right)::cur_state6.hypothesis;
                      hyp_tags = (InputTag occ)::cur_state6.hyp_tags
                    } proc;

                    output_rule { cur_state6 with
                      hyp_tags = (InputPTag occ) :: cur_state6.hyp_tags
                    } (Pred(cur_state6.input_pred, [left_state cur_state6.cur_cells; channel_left;
                                                    right_state cur_state6.cur_cells; channel_right]));

                    (* Pattern satisfied only on left side *)
                    output_rule { cur_state5 with
                      constra = [Neq(gen_pat_r,x_right)]::cur_state5.constra;
                      hypothesis = (mess_fact cur_state.cur_cells cur_state.cur_phase channel_left term_pat_left channel_right x_right)::cur_state5.hypothesis;
                      hyp_tags = TestUnifTag2(occ)::(InputTag occ)::cur_state5.hyp_tags
                    } (Pred(Param.bad_pred, []));

                    (* Pattern satisfied only on right side *)
                    output_rule { cur_state5 with
                      constra = [Neq(gen_pat_l,x_left)]::cur_state5.constra;
                      hypothesis = (mess_fact cur_state.cur_cells cur_state.cur_phase channel_left x_left channel_right term_pat_right)::cur_state5.hypothesis;
                      hyp_tags = TestUnifTag2(occ)::(InputTag occ)::cur_state5.hyp_tags
                    } (Pred(Param.bad_pred, []))

                  ) cur_state4  [term_pat_left] [term_pat_right];

                  (*  Case with left pattern succeed but right fail *)

                  transl_one_side_fails (fun cur_state5 ->
                    output_rule { cur_state5 with
                      hypothesis = (mess_fact cur_state.cur_cells cur_state.cur_phase channel_left term_pat_left channel_right x_right)::cur_state5.hypothesis;
                      hyp_tags = TestUnifTag2(occ)::(InputTag occ)::cur_state5.hyp_tags
                    } (Pred(Param.bad_pred, []))
                  ) cur_state4 [term_pat_right] [term_pat_left];

                  (*  Case with right pattern succeed but left fail *)

                  transl_one_side_fails (fun cur_state5 ->
                    output_rule { cur_state5 with
                      hypothesis = (mess_fact cur_state.cur_cells cur_state.cur_phase channel_left x_left channel_right term_pat_right)::cur_state5.hypothesis;
                      hyp_tags = TestUnifTag2(occ)::(InputTag occ)::cur_state5.hyp_tags
                    } (Pred(Param.bad_pred, []))
                  ) cur_state4 [term_pat_left] [term_pat_right]
                ) cur_state3 term_pattern
              ) cur_state2 pat
            ) cur_state1 [channel_left] [channel_right];

            (* Case left channel succeed and right channel fail *)
            transl_one_side_fails (fun cur_state2 ->
              output_rule { cur_state2 with
                hyp_tags = (TestUnifTag2 occ)::cur_state2.hyp_tags
              } (Pred(Param.bad_pred, []))
            ) cur_state1 [channel_right] [channel_left];

            (* Case right side succeed and left side fail *)
            transl_one_side_fails (fun cur_state2 ->
              output_rule { cur_state2 with
                hyp_tags = (TestUnifTag2 occ)::cur_state2.hyp_tags
              } (Pred(Param.bad_pred, []))
            ) cur_state1 [channel_left] [channel_right]
          ) cur_state (OInChannel(occ)) tc
      end

  | Output(term_ch, term, proc, occ) ->
      begin
        let cur_state = update_cells cur_state in
        match term_ch with
          | FunApp({ f_cat = Name _; f_private = false },_) when !Param.active_attacker ->
              transl_term (fun cur_state1 term_left term_right ->
                (* Case both sides succeed *)
                transl_both_side_succeed (fun cur_state2 ->
                  transl_process { cur_state2 with
                      hyp_tags = (OutputTag occ)::cur_state2.hyp_tags
                    } proc;

                  output_rule { cur_state2 with
                      hyp_tags = (OutputTag occ)::cur_state2.hyp_tags
                    } (att_fact cur_state2.cur_cells cur_state2.cur_phase term_left term_right)
                ) cur_state1 [term_left] [term_right];

                (* Case left side succeed and right side fail *)
                transl_one_side_fails (fun cur_state2 ->
                  output_rule { cur_state2 with
                    hyp_tags = (TestUnifTag2 occ)::cur_state2.hyp_tags
                  } (Pred(Param.bad_pred, []))
                ) cur_state1 [term_right] [term_left];

                (* Case right side succeed and left side fail *)
                transl_one_side_fails (fun cur_state2 ->
                  output_rule { cur_state2 with
                    hyp_tags = (TestUnifTag2 occ)::cur_state2.hyp_tags
                  } (Pred(Param.bad_pred, []))
                ) cur_state1 [term_left] [term_right]
              ) cur_state term
          | _ ->
              transl_term (fun cur_state1 channel_left channel_right ->
                transl_term (fun cur_state2 term_left term_right ->
                  (* Case both sides succeed *)
                  transl_both_side_succeed (fun cur_state3 ->
                    transl_process { cur_state3 with
                        hyp_tags = (OutputTag occ)::cur_state3.hyp_tags
                      } proc;

                    output_rule { cur_state3 with
                        hyp_tags = (OutputPTag occ) :: cur_state3.hyp_tags
                      } (Pred(cur_state3.output_pred, [left_state cur_state3.cur_cells; channel_left;
                                                       right_state cur_state3.cur_cells; channel_right]));

                    output_rule { cur_state3 with
                        hyp_tags = (OutputTag occ)::cur_state3.hyp_tags
                      } (mess_fact cur_state3.cur_cells cur_state3.cur_phase channel_left term_left channel_right term_right)
                  ) cur_state2 [channel_left;term_left] [channel_right;term_right];

                  (* Case left side succeed and right side fail *)
                  transl_one_side_fails (fun cur_state3 ->
                    output_rule { cur_state3 with
                      hyp_tags = (TestUnifTag2 occ)::cur_state3.hyp_tags
                    } (Pred(Param.bad_pred, []))
                  ) cur_state2 [channel_right;term_right] [channel_left;term_left];

                  (* Case right side succeed and left side fail *)
                  transl_one_side_fails (fun cur_state3 ->
                    output_rule { cur_state3 with
                      hyp_tags = (TestUnifTag2 occ)::cur_state3.hyp_tags
                    } (Pred(Param.bad_pred, []))
                  ) cur_state2 [channel_left;term_left] [channel_right;term_right]
                ) cur_state1 term
              ) cur_state term_ch
      end

  | LetFilter(_,_,_,_,_) ->
      user_error "Predicates are currently incompatible with proofs of equivalences.\n"

  | Event(t,p,occ) ->
      (* Even if the event does nothing, the term t is evaluated *)
      transl_term (fun cur_state1 term_left term_right ->
        (* Case both sides succeed *)
        transl_both_side_succeed (fun cur_state2 ->
	  transl_process cur_state2 p
	    ) cur_state1 [term_left] [term_right];

        (* Case left side succeeds and right side fails *)
        transl_one_side_fails (fun cur_state2 ->
          output_rule { cur_state2 with
            hyp_tags = (TestUnifTag2 occ)::cur_state2.hyp_tags
            } (Pred(Param.bad_pred, []))
        ) cur_state1 [term_right] [term_left];

        (* Case right side succeeds and left side fails *)
        transl_one_side_fails (fun cur_state2 ->
          output_rule { cur_state2 with
            hyp_tags = (TestUnifTag2 occ)::cur_state2.hyp_tags
            } (Pred(Param.bad_pred, []))
        ) cur_state1 [term_left] [term_right]

	  ) cur_state t

  | Insert(term,proc,occ) ->
      transl_term (fun cur_state1 term_left term_right ->
        (* Case both sides succeed *)
        transl_both_side_succeed (fun cur_state2 ->
          output_rule { cur_state2 with
            hyp_tags = (InsertTag occ) :: cur_state2.hyp_tags
          } (table_fact cur_state2.cur_phase term_left term_right);

          transl_process { cur_state2 with
            hyp_tags = (InsertTag occ) :: cur_state2.hyp_tags
          } proc;
        ) cur_state1 [term_left] [term_right];

        (* Case left side succeeds and right side fails *)
        transl_one_side_fails (fun cur_state2 ->
          output_rule { cur_state2 with
            hyp_tags = (TestUnifTag2 occ)::cur_state2.hyp_tags
            } (Pred(Param.bad_pred, []))
        ) cur_state1 [term_right] [term_left];

        (* Case right side succeeds and left side fails *)
        transl_one_side_fails (fun cur_state2 ->
          output_rule { cur_state2 with
            hyp_tags = (TestUnifTag2 occ)::cur_state2.hyp_tags
            } (Pred(Param.bad_pred, []))
        ) cur_state1 [term_left] [term_right]
      ) cur_state term

  | Get(pat,term,proc,proc_else,occ) ->
      transl_pat (fun cur_state1 term_pattern binders ->
        transl_term (fun cur_state2 term_pat_left term_pat_right ->

          let x_right = Terms.new_var_def (Terms.get_term_type term_pat_right)
          and x_left = Terms.new_var_def (Terms.get_term_type term_pat_right) in

          (* Generate the pattern with universal_variable *)
          let gen_pat_l, gen_pat_r = generate_pattern_with_uni_var binders term_pat_left term_pat_right in

          transl_term (fun cur_state3 term_left term_right ->

            (* Case both sides succeed *)
            transl_both_side_succeed (fun cur_state4 ->
              (* Success *)
              Terms.auto_cleanup (fun _ ->
		try
		  Terms.unify term_left Terms.true_term;
		  Terms.unify term_right Terms.true_term;
		  transl_process { cur_state4 with
                    name_params = (List.map
                      (fun b -> match b.link with
                         | TLink t -> t
                         | _ ->internal_error "unexpected link in translate_term (6)"
                      ) binders) @ cur_state4.name_params;
                    name_params_types = (List.map (fun b -> b.btype) binders)@cur_state4.name_params_types;
                    name_params_meaning = (List.map (fun b -> b.sname) binders)@cur_state4.name_params_meaning;
                    hypothesis = (table_fact cur_state4.cur_phase term_pat_left term_pat_right) :: cur_state4.hypothesis;
                    hyp_tags = (GetTag(occ)) :: cur_state4.hyp_tags;
                  } proc;
                with Terms.Unify -> ()
              );

              (* BAD (Left ok / Right ko) *)
              Terms.auto_cleanup (fun _ ->
		try
		  Terms.unify term_left Terms.true_term;
		  output_rule { cur_state4 with
                    hypothesis = (table_fact cur_state4.cur_phase term_pat_left term_pat_right) :: cur_state4.hypothesis;
                    constra = [Neq(term_right,Terms.true_term)]::cur_state4.constra;
                    hyp_tags = TestUnifTag2(occ)::(GetTag occ)::cur_state4.hyp_tags
                  } (Pred(Param.bad_pred, []));
                with Terms.Unify -> ()
              );

              Terms.auto_cleanup (fun _ ->
		try
		  Terms.unify term_left Terms.true_term;
		  output_rule { cur_state4 with
                    hypothesis = (table_fact cur_state4.cur_phase term_pat_left x_right) :: cur_state4.hypothesis;
                    constra = [Neq(x_right,gen_pat_r)]::cur_state4.constra;
                    hyp_tags = TestUnifTag2(occ)::(GetTag(occ))::cur_state4.hyp_tags
                  } (Pred(Param.bad_pred, []));
                with Terms.Unify -> ()
              );

              (* BAD (Left ko / Right ok) *)
              Terms.auto_cleanup (fun _ ->
		try
		  Terms.unify term_right Terms.true_term;
		  output_rule { cur_state4 with
                    hypothesis = (table_fact cur_state4.cur_phase term_pat_left term_pat_right) :: cur_state4.hypothesis;
                    constra = [Neq(term_left,Terms.true_term)]::cur_state4.constra;
                    hyp_tags = TestUnifTag2(occ)::(GetTag(occ))::cur_state4.hyp_tags
                  } (Pred(Param.bad_pred, []));
                with Terms.Unify -> ()
              );

              Terms.auto_cleanup (fun _ ->
		try
		  Terms.unify term_right Terms.true_term;
		  output_rule { cur_state4 with
                    hypothesis = (table_fact cur_state4.cur_phase x_left term_pat_right) :: cur_state4.hypothesis;
                    constra = [Neq(x_left,gen_pat_l)]::cur_state4.constra;
                    hyp_tags = TestUnifTag2(occ)::(GetTag(occ))::cur_state4.hyp_tags
                  } (Pred(Param.bad_pred, []))
                with Terms.Unify -> ()
              )
            ) cur_state3 [term_pat_left;term_left] [term_pat_right;term_right];

            (* Case left side succeed and right side fail *)
            transl_one_side_fails (fun cur_state4 ->
              (* BAD *)
              Terms.auto_cleanup (fun _ ->
		try
		  Terms.unify term_left Terms.true_term;
		  output_rule { cur_state4 with
                    hypothesis = (table_fact cur_state4.cur_phase term_pat_left x_right) :: cur_state4.hypothesis;
                    hyp_tags = TestUnifTag2(occ)::(GetTag(occ))::cur_state4.hyp_tags
                  } (Pred(Param.bad_pred, []))
                with Terms.Unify -> ()
              )
            ) cur_state3 [term_pat_right;term_right] [term_pat_left;term_left];

            (* Case right side succeed and left side fail *)
            transl_one_side_fails (fun cur_state4 ->
              (* BAD *)
              Terms.auto_cleanup (fun _ ->
		try
		  Terms.unify term_right Terms.true_term;
                  output_rule { cur_state4 with
                    hypothesis = (table_fact cur_state4.cur_phase x_left term_pat_right) :: cur_state4.hypothesis;
                    hyp_tags = TestUnifTag2(occ)::(GetTag(occ))::cur_state4.hyp_tags
                  } (Pred(Param.bad_pred, []))
                with Terms.Unify -> ()
              )
            ) cur_state3 [term_pat_left;term_left] [term_pat_right;term_right]

          ) cur_state2 term
       ) cur_state1 term_pattern
     ) cur_state pat;
     transl_process { cur_state with hyp_tags = GetTagElse(occ) :: cur_state.hyp_tags } proc_else

  | Phase(n,proc,_) ->
      transl_process { cur_state with
                       input_pred = Param.get_pred (InputPBin(n));
                       output_pred = Param.get_pred (OutputPBin(n));
                       cur_phase = n } proc

  | Lock(cells, proc, occ)
  | Unlock(cells, proc, occ) ->
      let new_locked = match process with Lock _ -> true | _ -> false in
      let cur_state = invalidate_cells cur_state in
      transl_process { cur_state with cur_cells =
        List.fold_left (fun cur_cells s ->
          FunMap.add (s, "")
            { (FunMap.find (s, "") cur_cells) with
              locked = new_locked }
            cur_cells
        ) cur_state.cur_cells cells
      } proc

  | Open(cells, proc, occ) ->
      List.iter (fun s ->
        output_rule { cur_state with hyp_tags = (OpenTag occ) :: cur_state.hyp_tags }
          (att_fact cur_state.cur_cells cur_state.cur_phase (FunApp(s,[])) (FunApp(s,[])))) cells;
      transl_process cur_state proc

  | Assign(items, proc, occ) ->
       let cur_state = update_cells (invalidate_cells cur_state) in
       transl_term_list (fun cur_state1 terms_left terms_right ->
         (* Case both sides succeed. *)
         transl_both_side_succeed (fun cur_state2 ->
           let updated_cells = List.fold_left2
             (fun cells (s, _) (term_left, term_right) ->
               FunMap.add (s, "")
                 { (FunMap.find (s, "") cells) with
                   left_value = term_left;
                   right_value = term_right;
                   valid = true }
               cells
             ) cur_state2.cur_cells items (List.combine terms_left terms_right)
           in
           output_rule { cur_state2 with
             hyp_tags = (AssignTag(occ, List.map fst items))::cur_state2.hyp_tags
           } (Pred(Param.get_pred (SeqBin(cur_state2.cur_phase)),
                   [left_state cur_state2.cur_cells; left_state updated_cells;
                    right_state cur_state2.cur_cells; right_state updated_cells]));
           (* TODO: Always output sequence hypothesis here? *)
           let cur_state3 = { cur_state2 with
             cur_cells = updated_cells;
             hypothesis = (Pred(Param.get_pred (SeqBin(cur_state2.cur_phase)),
                                [left_state cur_state2.cur_cells; left_state updated_cells;
                                 right_state cur_state2.cur_cells; right_state updated_cells]))
                        :: cur_state2.hypothesis; (* TODO: Discard old hypotheses? *)
             hyp_tags = SequenceTag :: cur_state2.hyp_tags
           } in

           transl_process cur_state3 proc
         ) cur_state1 terms_left terms_right;

         (* Case left side succeeds and right side fails. *)
         transl_one_side_fails (fun cur_state2 ->
           output_rule {cur_state2 with
               hyp_tags = (TestUnifTag2 occ)::cur_state2.hyp_tags
             } (Pred(Param.bad_pred, []))
         ) cur_state1 terms_right terms_left;

         (* Case right side succeeds and left side fails. *)
         transl_one_side_fails (fun cur_state2 ->
           output_rule {cur_state2 with
               hyp_tags = (TestUnifTag2 occ)::cur_state2.hyp_tags
             } (Pred(Param.bad_pred, []))
         ) cur_state1 terms_left terms_right
       ) cur_state (List.map snd items)

  | ReadAs(items, proc, occ) ->
      let cur_state = update_cells (invalidate_cells cur_state) in
      transl_pat_list (fun cur_state1 terms_pattern binders ->
        transl_term_list (fun cur_state2 terms_pat_left terms_pat_right ->
          let gen_pats_l, gen_pats_r = List.split (
            List.map2 (fun term_pat_left term_pat_right ->
              generate_pattern_with_uni_var binders term_pat_left term_pat_right
            ) terms_pat_left terms_pat_right
          ) in

          transl_both_side_succeed (fun cur_state3 ->
            (* Pattern satisfied in both sides. *)
            begin try Terms.auto_cleanup (fun () ->
              unify_cells cur_state2 (fun x -> x.left_value) items terms_pat_left;
              unify_cells cur_state2 (fun x -> x.right_value) items terms_pat_right;
              transl_process { cur_state3 with
                  name_params = (List.map
                    (fun b -> match b.link with
                       | TLink t -> t
                       | _ -> internal_error "unexpected link in translate_term (7)"
                    ) binders) @ cur_state3.name_params;
                  name_params_types = (List.map (fun b -> b.btype) binders) @ cur_state3.name_params_types;
                  name_params_meaning = (List.map (fun b -> b.sname) binders) @ cur_state3.name_params_meaning
                } proc;
            ) with Terms.Unify -> () end;

            (* Pattern satisfied only on left side. *)
            begin try Terms.auto_cleanup (fun () ->
              unify_cells cur_state2 (fun x -> x.left_value) items terms_pat_left;
              output_rule { cur_state3 with
                  constra = (List.map2 (fun (cell, _) gen_pat_r ->
                        [Neq((FunMap.find (cell, "") cur_state3.cur_cells).right_value, gen_pat_r)]
                      ) items gen_pats_r)
                    @ cur_state3.constra;
                  hyp_tags = TestUnifTag2(occ) :: cur_state3.hyp_tags
                } (Pred(Param.bad_pred, []))
            ) with Terms.Unify -> () end;

            (* Pattern satisfied only on right side. *)
            begin try Terms.auto_cleanup (fun () ->
              unify_cells cur_state2 (fun x -> x.right_value) items terms_pat_right;
              output_rule { cur_state3 with
                constra = (List.map2 (fun (cell, _) gen_pat_l ->
                      [Neq((FunMap.find (cell, "") cur_state3.cur_cells).left_value, gen_pat_l)]
                    ) items gen_pats_l)
                  @ cur_state3.constra;
                hyp_tags = TestUnifTag2(occ) :: cur_state3.hyp_tags
              } (Pred(Param.bad_pred, []))
            ) with Terms.Unify -> () end;
          ) cur_state2 terms_pat_left terms_pat_right;

          (* Case left side succeeds and right side fails. *)
          transl_one_side_fails (fun cur_state3 ->
            output_rule { cur_state3 with
                hyp_tags = (TestUnifTag2 occ) :: cur_state3.hyp_tags
              } (Pred(Param.bad_pred, []))
          ) cur_state2 terms_pat_right terms_pat_left;

          (* Case right side succeeds and left side fails. *)
          transl_one_side_fails (fun cur_state3 ->
            output_rule { cur_state3 with
                hyp_tags = (TestUnifTag2 occ) :: cur_state3.hyp_tags
              } (Pred(Param.bad_pred, []))
          ) cur_state2 terms_pat_left terms_pat_right;
        ) cur_state1 terms_pattern
      ) cur_state (List.map snd items)



(***********************************
	The attacker clauses
************************************)


(* Clauses corresponding to an application of a function

   [rules_Rf_for_red] does not need the rewrite rules f(...fail...) -> fail
   for categories Eq and Tuple in [red_rules]. Indeed, clauses
   that come from these rewrite rules are useless:
       1/ if we use twice the same of these rewrite rules, we get
       att(u1,u1') & ... & att(fail_ti, fail_ti) & ... & att(un,un') -> att(fail, fail)
       which is subsumed by att(fail, fail)
       2/ if we use two distinct such rewrite rules, we get
       att(u1,u1') & ... & att(fail_ti, ui') & ... & att(uj, fail_tj) & ... & att(un,un') -> att(fail, fail)
       which is subsumed by att(fail, fail)
       3/ if we use one such rewrite rule and another rewrite rule, we get
       att(u1,M1) & ... & att(fail_ti, Mi) & ... & att(un, Mn) -> att(fail, M')
       which is subsumed by att(fail_ti, x) -> bad (recall that bad subsumes all conclusions)
       Mi are messages, they are not fail nor may-fail variables. *)

let rules_Rf_for_red phase f_symb red_rules =
  let result_predicate = Param.get_pred (AttackerBin(phase, snd f_symb.f_type)) in
  if phase < !min_choice_phase then
    (* Optimize generation when no choice in the current phase *)
    List.iter (fun red_rule ->
      let (hyp1, concl1, side_c1) = Terms.copy_red red_rule in

      let vs = match hyp1 with
        | [] when phase = 0 -> Some (initial_state())
        | [] -> None
        | _ -> Some (new_state()) in
      match vs with
        | None -> () (* inherited from phase 0 *)
        | Some vs ->
          add_rule (List.map (fun t1 -> att_fact vs phase t1 t1) hyp1)
      	    (att_fact vs phase concl1 concl1)
      	    (List.map (fun (t1,t2) -> [Neq(t1,t2)]) side_c1)
      	    (Apply(f_symb, result_predicate))
            ) red_rules
  else
    List.iter (fun red_rule1 ->
      List.iter (fun red_rule2 ->
        let (hyp1, concl1, side_c1) = Terms.copy_red red_rule1
        and (hyp2, concl2, side_c2) = Terms.copy_red red_rule2 in

        let vs = match hyp1, hyp2 with
          | [], [] when phase = 0 -> Some (initial_state())
          | [], [] -> None
          | _ -> Some (new_state()) in
        match vs with
          | None -> () (* inherited from phase 0 *)
          | Some vs ->
            add_rule (List.map2 (fun t1 t2 -> att_fact vs phase t1 t2) hyp1 hyp2)
      	      (att_fact vs phase concl1 concl2)
      	      ((List.map (fun (t1,t2) -> [Neq(t1,t2)]) side_c1) @ (List.map (function (t1,t2) -> [Neq(t1,t2)]) side_c2))
      	      (Apply(f_symb, result_predicate))
      	      ) red_rules
      	    ) red_rules

let transl_attacker phase =

  (* The attacker can apply all functions, including tuples *)
  Hashtbl.iter (Terms.clauses_for_function (rules_Rf_for_red phase)) Param.fun_decls;
  Hashtbl.iter (Terms.clauses_for_function (rules_Rf_for_red phase)) Terms.tuple_table;

  (* The attacker can read any opened cells. *)
  (*
  List.iter (fun (s,_) ->
    (* TODO: Suppress this clause for cells that are never opened? *)
    let vs = new_state () in
    let (_, v1, v2) = FunMap.find (s,"") vs in
    add_rule [att_fact vs phase (FunApp(s,[])) (FunApp(s,[]))]
      (att_fact vs phase v1 v2) [] Rread) !Param.cells;*)

  List.iter (fun t ->
    let att_pred = Param.get_pred (AttackerBin(phase,t)) in
    let mess_pred = Param.get_pred (MessBin(phase,t)) in
    let seq_pred = Param.get_pred (SeqBin(phase)) in

    (* The attacker has any message sent on a channel he has (Rule Rl)*)
    let vs = new_state () in
    let v1 = Terms.new_var_def t in
    let vc1 = Terms.new_var_def Param.channel_type in
    let v2 = Terms.new_var_def t in
    let vc2 = Terms.new_var_def Param.channel_type in
    add_rule [Pred(mess_pred, [left_state vs; vc1; v1; right_state vs; vc2; v2]); att_fact vs phase vc1 vc2]
      (Pred(att_pred, [left_state vs; v1; right_state vs; v2])) [] (Rl(att_pred, mess_pred));

    if (!Param.active_attacker) then
      begin
        (* The attacker can send any message he has on any channel he has (Rule Rs) *)
	let vs = new_state () in
	let v1 = Terms.new_var_def t in
	let vc1 = Terms.new_var_def Param.channel_type in
	let v2 = Terms.new_var_def t in
	let vc2 = Terms.new_var_def Param.channel_type in
	add_rule [att_fact vs phase vc1 vc2; Pred(att_pred, [left_state vs; v1; right_state vs; v2])]
          (Pred(mess_pred, [left_state vs; vc1; v1; right_state vs; vc2; v2])) [] (Rs(att_pred, mess_pred));

        (*
        (* The attacker can write any opened cells. *)
        List.iter (fun ({f_type=(_,cell_type)} as s,_) ->
          (* TODO: Suppress this clause for cells that are never opened? *)
          let [v1;vc1;vm1;v2;vc2;vm2] = List.map Terms.new_var_def
            [cell_type; Param.channel_type; t; cell_type; Param.channel_type; t] in
          let vs = new_state () in
          let vs' = FunMap.add (s,"") (false, v1, v2) vs in
          add_rule [att_fact vs phase (FunApp(s,[])) (FunApp(s,[]));
                    att_fact vs phase v1 v2;
                    Pred(mess_pred, [left_state vs; vc1; vm1; right_state vs; vc2; vm2])]
            (Pred(mess_pred, [left_state vs'; vc1; vm1; right_state vs'; vc2; vm2]))
            [] (Rwrite(mess_pred))) !Param.cells;*)

      end;

    (* State sequencing. *)
    let vs1 = new_state () in
    (* TODO: Move these outside the iteration over all types! *)
    add_rule [] (Pred(seq_pred,
        [left_state vs1; left_state vs1; right_state vs1; right_state vs1]))
      [] (Rseq0 seq_pred);
    let vs1 = new_state () in
    let vs2 = new_state () in
    let vs3 = new_state () in
    add_rule [Pred(seq_pred, [left_state vs1; left_state vs2; right_state vs1; right_state vs2]);
              Pred(seq_pred, [left_state vs2; left_state vs3; right_state vs2; right_state vs3])]
      (Pred(seq_pred, [left_state vs1; left_state vs3; right_state vs1; right_state vs3]))
      [] (Rseq1 seq_pred);
    let vs1 = new_state () in
    let vs2 = new_state () in
    let v1 = Terms.new_var_def t in
    let v2 = Terms.new_var_def t in
    add_rule [Pred(seq_pred, [left_state vs1; left_state vs2; right_state vs1; right_state vs2]);
              Pred(att_pred, [left_state vs1; v1; right_state vs1; v2])]
      (Pred(att_pred, [left_state vs2; v1; right_state vs2; v2])) [] (Rinherit(seq_pred, att_pred));


    (* Clauses for equality *)
    let v = Terms.new_var_def t in
    add_rule [] (Pred(Param.get_pred (Equal(t)), [v;v])) [] LblEq;

    (* Check for destructor failure (Rfailure) *)

    if phase >= !min_choice_phase
    then
      begin
        let vs = new_state () in
        let x = Terms.new_var_def t
        and fail = Terms.get_fail_term t in

        add_rule [Pred(att_pred, [left_state vs; x; right_state vs; fail])] (Pred(Param.bad_pred, [])) [] (Rfail(att_pred));
        add_rule [Pred(att_pred, [left_state vs; fail; right_state vs; x])] (Pred(Param.bad_pred, [])) [] (Rfail(att_pred))
      end;


  ) (all_types());

  if phase >= !min_choice_phase then
    begin
      let att_pred = Param.get_pred (AttackerBin(phase,Param.channel_type)) in
      let input_pred = Param.get_pred (InputPBin(phase)) in
      let output_pred = Param.get_pred (OutputPBin(phase)) in

      (* The attacker can do communications (Rule Ri and Ro) *)
      let vs = new_state () in
      let vc1 = Terms.new_var_def Param.channel_type in
      let vc2 = Terms.new_var_def Param.channel_type in
      add_rule [Pred(att_pred, [left_state vs; vc1; right_state vs; vc2])]
               (Pred(input_pred, [left_state vs; vc1; right_state vs; vc2])) [] (Ri(att_pred, input_pred));
      let vs = new_state () in
      let vc1 = Terms.new_var_def Param.channel_type in
      let vc2 = Terms.new_var_def Param.channel_type in
      add_rule [Pred(att_pred, [left_state vs; vc1; right_state vs; vc2])]
               (Pred(output_pred, [left_state vs; vc1; right_state vs; vc2])) [] (Ro(att_pred, output_pred));

      (* Check communications do not reveal secrets (Rule Rcom and Rcom')*)
      let vs = new_state () in
      let vc = Terms.new_var_def Param.channel_type in
      let vc1 = Terms.new_var_def Param.channel_type in
      let vc2 = Terms.new_var_def Param.channel_type in
      add_rule [Pred(input_pred, [left_state vs; vc; right_state vs; vc1]);
		 Pred(output_pred, [left_state vs; vc; right_state vs; vc2])]
	 (Pred(Param.bad_pred, [])) [[Neq(vc1,vc2)]]
	 (TestComm(input_pred, output_pred));
	
      let vs = new_state () in
      let vc = Terms.new_var_def Param.channel_type in
      let vc1 = Terms.new_var_def Param.channel_type in
      let vc2 = Terms.new_var_def Param.channel_type in
      add_rule [Pred(input_pred, [left_state vs; vc1; right_state vs; vc]);
		 Pred(output_pred, [left_state vs; vc2; right_state vs; vc])]
	(Pred(Param.bad_pred, [])) [[Neq(vc1,vc2)]]
	(TestComm(input_pred, output_pred))

     end

(* Convert terms (possibly with choice) to one term or to
   a pair of terms.
   You need to cleanup links after calling convert_to_1 and
   convert_to_2. *)

let rec convert_to_2 = function
    Var x ->
      begin
	match x.link with
	  TLink (FunApp(_,[t1;t2])) -> (t1,t2)
	| NoLink ->
	    let x1 = Var (Terms.copy_var x) in
	    let x2 = Var (Terms.copy_var x) in
	    Terms.link x (TLink (FunApp(Param.choice_fun x.btype, [x1; x2])));
	    (x1, x2)
	| _ -> assert false
      end
  | FunApp(f, [t1;t2]) when f.f_cat == Choice ->
      let (t1',_) = convert_to_2 t1 in
      let (_,t2') = convert_to_2 t2 in
      (t1', t2')
  | FunApp(f, l) ->
      match f.f_cat with
	Name { prev_inputs_meaning = pim } ->
	  let l' = List.map2 (fun t s ->
	    if (s <> "") && (s.[0] = '!') then
	      try
		convert_to_1 t
	      with Terms.Unify ->
		user_error "Error: In not declarations, session identifiers should be variables.\n"
	    else
	      (* The arguments of names are always choice, except for session identifiers *)
	      let (t1,t2) = convert_to_2 t in
	      FunApp(Param.choice_fun (Terms.get_term_type t1), [t1;t2])
	      ) l pim
	  in
	  (FunApp(f, l'), FunApp(f, l'))
      |	_ ->
	  let (l1, l2) = List.split (List.map convert_to_2 l) in
	  (FunApp(f, l1), FunApp(f, l2))

(* convert_to_1 raises Terms.Unify when there is a choice
   that cannot be unified into one term. *)

and convert_to_1 t =
  let (t1, t2) = convert_to_2 t in
  Terms.unify t1 t2;
  t1

let convert_to_2 t =
  let (t1, t2) = convert_to_2 t in
  (Terms.copy_term2 t1, Terms.copy_term2 t2)

let convert_to_1 t =
  Terms.copy_term2 (convert_to_1 t)

(* Convert formats (possibly with choice) to one format or to
   a pair of formats.
   Since nounif cannot be used for a phase earlier than the
   one mentioned in the nounif declaration, it is not essential
   that we can convert a nounif made with choice into a single format.
   Moreover, we do not have a unification for formats ready,
   so we prefer forbidding choice when a single format is needed.
 *)

let rec convertformat_to_1 = function
    FVar x -> FVar x
  | FAny x -> FAny x
  | FFunApp(f, [t1;t2]) when f.f_cat == Choice ->
      Parsing_helper.user_error "Error: choice not allowed in nounif declarations for phases in which choice is not used in the process\n"
  | FFunApp(f, l) ->
      match f.f_cat with
	Name { prev_inputs_meaning = pim } ->
	  (* The arguments of names are always choice *)
	  let l' = List.map2 (fun t s ->
	    if (s <> "") && (s.[0] = '!') then
	      convertformat_to_1 t
	    else
	      let t' = convertformat_to_1 t in
	      FFunApp(Param.choice_fun (Terms.get_format_type t'), [t';t'])
		) l pim
	  in
	  FFunApp(f, l')
      |	_ ->
	  FFunApp(f, List.map convertformat_to_1 l)

(* You need to cleanup links after calling convertformat_to_2 *)

let rec convertformat_to_2 = function
    FVar x ->
      begin
	match x.link with
	  TLink (FunApp(_,[Var x1;Var x2])) -> (FVar x1,FVar x2)
	| NoLink ->
	    if x.btype == Param.sid_type then
	      Parsing_helper.internal_error "convertformat_to_2: session identifiers should occur only inside names (1)\n";
	    let x1 = Terms.copy_var x in
	    let x2 = Terms.copy_var x in
	    Terms.link x (TLink (FunApp(Param.choice_fun x.btype, [Var x1; Var x2])));
	    (FVar x1, FVar x2)
	| _ -> assert false
      end
  | FAny x ->
      begin
	match x.link with
	  TLink (FunApp(_,[Var x1;Var x2])) -> (FAny x1,FAny x2)
	| NoLink ->
	    if x.btype == Param.sid_type then
	      Parsing_helper.internal_error "convertformat_to_2: session identifiers should occur only inside names (2)\n";
	    let x1 = Terms.copy_var x in
	    let x2 = Terms.copy_var x in
	    Terms.link x (TLink (FunApp(Param.choice_fun x.btype, [Var x1; Var x2])));
	    (FAny x1, FAny x2)
	| _ -> assert false
      end
  | FFunApp(f, [t1;t2]) when f.f_cat == Choice ->
      let (t1',_) = convertformat_to_2 t1 in
      let (_,t2') = convertformat_to_2 t2 in
      (t1', t2')
  | FFunApp(f, l) ->
      match f.f_cat with
	Name { prev_inputs_meaning = pim } ->
	  (* The arguments of names are always choice, except for
	     session identifiers *)
	  let l' = List.map2 (fun t s ->
	    if (s <> "") && (s.[0] = '!') then
	      begin
		match t with
		  FVar x -> assert (x.btype == Param.sid_type); FVar x
		| FAny x -> assert (x.btype == Param.sid_type); FAny x
		| _ -> Parsing_helper.user_error "Error: In nounif declarations, session identifiers should be variables.\n"
	      end
	    else
	      let (t1,t2) = convertformat_to_2 t in
	      FFunApp(Param.choice_fun (Terms.get_format_type t1), [t1;t2])
		) l pim
	  in
	  (FFunApp(f, l'), FFunApp(f, l'))
      |	_ ->
	  let (l1, l2) = List.split (List.map convertformat_to_2 l) in
	  (FFunApp(f, l1), FFunApp(f, l2))

(* Global translation *)

let transl p =
  Rules.reset ();
  Reduction_helper.main_process := p;
  Reduction_helper.terms_to_add_in_name_params := [];
  nrule := 0;
  red_rules := [];

  find_min_choice_phase 0 p;
  Reduction_helper.min_choice_phase := !min_choice_phase;

  (* Initialize the selection function.
     In particular, when there is a predicate
       member:x,y -> member:x,cons(z,y)
     we would like nounif member:*x,y
     It is important to initialize this very early, so that
     the simplification of the initial rules is performed with
     the good selection function. *)
  List.iter (fun r -> ignore(Selfun.selection_fun r)) (!red_rules);

  for i = 0 to !Param.max_used_phase do

    transl_attacker i;

    List.iter (fun t ->
      (* The attacker has the fail constants *)
      let fail_term = Terms.get_fail_term t in
      add_rule [] (att_fact (initial_state()) i fail_term fail_term) [] Init;

      let att_i = Param.get_pred (AttackerBin(i,t)) in
      if i < !min_choice_phase then
        begin
	  (* Phase coded by unary predicates *)
	  let v = Terms.new_var Param.def_var_name t in
	  let att_i = Param.get_pred (Attacker(i,t)) in
	  Selfun.add_no_unif (att_i, [new_state_format(); FVar v]) Selfun.never_select_weight
	end
      else
	begin
	  (*

	  (* Phase coded by binary predicates *)
	  let v1 = Terms.new_var Param.def_var_name t in
	  let v2 = Terms.new_var Param.def_var_name t in
	  Selfun.add_no_unif (att_i, [new_state_format(); FVar v1; new_state_format(); FVar v2]) Selfun.never_select_weight;
	  (* nounif attacker2(*vs1,vm1,*vs2,vm2)       *)*)
	  (*Selfun.add_no_unif (att_i, [new_state_formatv(); FAny v1; new_state_formatv(); FAny v2]) Selfun.never_select_weight;*)
	  (* nounif mess2(*vs,vc,vm,*vs2,vc2,vm2)   *)*)
	  let mess_i = Param.get_pred (MessBin(i,t)) in
	  let [vc1;vm1;vc2;vm2] = List.map (Terms.new_var Param.def_var_name)
	    [Param.channel_type; t; Param.channel_type; t] in
	  Selfun.add_no_unif (mess_i, [new_state_format(); FVar vc1; FVar vm1;
	                               new_state_format(); FVar vc2; FVar vm2]) Selfun.never_select_weight;
	  (*Selfun.add_no_unif (mess_i, [new_state_formatv(); FAny vc1; FAny vm1;
	                               new_state_formatv(); FAny vc2; FAny vm2]) Selfun.never_select_weight;*)
	  (* nounif output2(*vs1,*vc1,*vs2,*vc2) *)*)
	  let [vc1;vc2] = List.map (Terms.new_var Param.def_var_name)
	    [Param.channel_type; Param.channel_type] in
	  Selfun.add_no_unif (Param.get_pred (OutputPBin(i)),
	    [new_state_format(); FVar vc1; new_state_format(); FVar vc2])
	    Selfun.never_select_weight;
	  (* nounif input2(*vs1,*vc1,*vs2,*vc2) *)*)
	  let [vc1;vc2] = List.map (Terms.new_var Param.def_var_name)
	    [Param.channel_type; Param.channel_type] in
	  Selfun.add_no_unif (Param.get_pred (InputPBin(i)),
	    [new_state_format(); FVar vc1; new_state_format(); FVar vc2])
	    Selfun.never_select_weight

	  *)()
	end;
	
      if i > 0 then
	(* It is enough to transmit only messages from one phase to the next,
	   because the attacker already has (fail, fail) in all phases
	   and the cases (fail, x) and (x, fail) immediately lead
	   to bad in all cases. *)
	let vs = new_state () in
	let w1 = Terms.new_var_def t in
	let w2 = Terms.new_var_def t in
	let att_im1 = Param.get_pred (AttackerBin(i-1,t)) in
	add_rule [Pred(att_im1, [left_state vs; w1; right_state vs; w2])]
	  (Pred(att_i, [left_state vs; w1; right_state vs; w2])) [] PhaseChange
    ) (all_types());

    if i > 0 then
      let w1 = Terms.new_var_def Param.table_type in
      let w2 = Terms.new_var_def Param.table_type in
      let tbl_i = Param.get_pred (TableBin(i)) in
      let tbl_im1 = Param.get_pred (TableBin(i-1)) in
      add_rule [Pred(tbl_im1, [w1; w2])] (Pred(tbl_i, [w1; w2])) [] TblPhaseChange

  done;


   (* Knowing the free names and creating new names is necessary only in phase 0.
      The subsequent phases will get them by attacker'_i(x,y) -> attacker'_{i+1}(x,y) *)

   (* The attacker has the public free names *)
   List.iter (fun ch ->
      if not ch.f_private then
        add_rule [] (att_fact (initial_state()) 0 (FunApp(ch, [])) (FunApp(ch, []))) [] Init) (!Param.freenames);

   List.iter (fun t ->
     (* The attacker can create new names *)
     let v1 = Terms.new_var_def Param.sid_type in
     let new_name_fun = Terms.new_name_fun t in			
     add_rule [] (att_fact (initial_state()) 0 (FunApp(new_name_fun, [v1])) (FunApp(new_name_fun, [v1])))
       [] (Rn (Param.get_pred (AttackerBin(0, t))));

     (* Rules that derive bad are necessary only in the last phase.
        Previous phases will get them by attacker'_i(x,y) -> attacker'_{i+1}(x,y) *)
	
     let att_pred = Param.get_pred (AttackerBin(!Param.max_used_phase, t)) in

     (* The attacker can perform equality tests *)
     let vs = new_state () in
     let v1 = Terms.new_var_def t in
     let v2 = Terms.new_var_def t in
     let v3 = Terms.new_var_def t in
     add_rule [Pred(att_pred, [left_state vs; v1; right_state vs; v2]);
               Pred(att_pred, [left_state vs; v1; right_state vs; v3])]
       (Pred(Param.bad_pred, [])) [[Neq(v2,v3)]] (TestEq(att_pred));

     let vs = new_state () in
     let v1 = Terms.new_var_def t in
     let v2 = Terms.new_var_def t in
     let v3 = Terms.new_var_def t in
     add_rule [Pred(att_pred, [left_state vs; v2; right_state vs; v1]);
               Pred(att_pred, [left_state vs; v3; right_state vs; v1])]
       (Pred(Param.bad_pred, [])) [[Neq(v2,v3)]] (TestEq(att_pred))

   ) (all_types());

   List.iter (fun ch ->
     match ch.f_cat with
       | Name r -> r.prev_inputs <- Some (FunApp(ch, []))
       | _ -> internal_error "should be a name 1"
   ) (!Param.freenames);

   (* Translate the process into clauses *)

   Terms.auto_cleanup (fun _ -> transl_process
     { hypothesis = []; constra = [];
       name_params = []; name_params_types = []; name_params_meaning = [];
       repl_count = 0;
       input_pred = Param.get_pred (InputPBin(0));
       output_pred = Param.get_pred (OutputPBin(0));
       cur_phase = 0;
       cur_cells = initial_state ();
       hyp_tags = [];
     } p;
   );

   List.iter (fun ch -> match ch.f_cat with
     Name r -> r.prev_inputs <- None
   | _ -> internal_error "should be a name 2")
    (!Param.freenames);

   (* Take into account "not fact" declarations (secrecy assumptions) *)

   List.iter (function
       QFact({ p_info = [Attacker(i,ty)] },[t]) ->
      	 (* For attacker: not declarations, the not declaration is also
	    valid in previous phases, because of the implication
	      attacker_p(i):x => attacker_p(i+1):x
	    Furthermore, we have to translate unary to binary not declarations *)
	 for j = 0 to i do
	   if j < !min_choice_phase then
	     (* Phase coded by unary predicate, since it does not use choice *)
	     let att_j = Param.get_pred (Attacker(j,ty)) in
	     try
	       Rules.add_not(Pred(att_j,[Terms.auto_cleanup (fun () -> convert_to_1 t)]))
	     with Terms.Unify -> ()
	   else
	     (* Phase coded by binary predicate *)
	     let att2_j = Param.get_pred (AttackerBin(j,ty)) in
	     let (t',t'') = Terms.auto_cleanup (fun () -> convert_to_2 t) in
	     Rules.add_not(Pred(att2_j,[t';t'']))
	 done
     | QFact({ p_info = [Mess(i,ty)] } as p,[t1;t2]) ->
	 (* translate unary to binary not declarations *)
	 if i < !min_choice_phase then
	   (* Phase coded by unary predicate, since it does not use choice *)
	   try
	     let t1', t2' = Terms.auto_cleanup (fun () ->
	       convert_to_1 t1, convert_to_1 t2)
	     in
	     Rules.add_not(Pred(p, [t1'; t2']))
	   with Terms.Unify -> ()
	 else
	   (* Phase coded by binary predicate *)
	   let mess2_i = Param.get_pred (MessBin(i,ty)) in
	   let (t1', t1''), (t2', t2'') = Terms.auto_cleanup (fun () ->
	     convert_to_2 t1, convert_to_2 t2)
	   in
	   Rules.add_not(Pred(mess2_i,[t1';t2';t1'';t2'']))
     | _ -> Parsing_helper.user_error "The only allowed facts in \"not\" declarations are attacker: and mess: predicates (for process equivalences, user-defined predicates are forbidden).\n"
	   ) (if !Param.typed_frontend then Pitsyntax.get_not() else Pisyntax.get_not());

  (* Take into account "nounif" declarations *)
	
  List.iter (function (f,n) ->
    (* translate unary to binary nounif declarations *)
    match f with
      ({ p_info = [Attacker(i,ty)] } as pred, [t]) ->
	if i < !min_choice_phase then
	  (* Phase coded by unary predicate, since it does not use choice *)
	  Selfun.add_no_unif (pred, [convertformat_to_1 t]) n
	else
	  (* Phase coded by binary predicate *)
	  let att2_i = Param.get_pred (AttackerBin(i,ty)) in
	  let (t', t'') = Terms.auto_cleanup (fun () -> convertformat_to_2 t) in
	  Selfun.add_no_unif (att2_i, [t';t'']) n
    | ({ p_info = [Mess(i,ty)] } as pred, [t1;t2]) ->
	if i < !min_choice_phase then
	  (* Phase coded by unary predicate, since it does not use choice *)
	  Selfun.add_no_unif (pred, [convertformat_to_1 t1; convertformat_to_1 t2]) n
	else
	  (* Phase coded by binary predicate *)
	  let mess2_i = Param.get_pred (MessBin(i,ty)) in
	  let (t1', t1''), (t2', t2'') =
	    Terms.auto_cleanup (fun () ->
	      convertformat_to_2 t1,
	      convertformat_to_2 t2)
	  in
	  Selfun.add_no_unif (mess2_i,[t1';t2';t1'';t2'']) n
    | ({ p_info = [SeqBin(i)] } as pred, tl) ->
        if i < !min_choice_phase then
          Parsing_helper.user_error "seq2 cannot be used in phases before \"choice\" is used.\n";
        Selfun.add_no_unif (pred, List.map convertformat_to_1 tl) n
    | _ -> Parsing_helper.user_error "The only allowed facts in \"nounif\" declarations are attacker: and mess: predicates (for process equivalences, user-defined predicates are forbidden).\n"
	  ) (if !Param.typed_frontend then Pitsyntax.get_nounif() else Pisyntax.get_nounif());

  List.rev (!red_rules)

(* This code was used to renumber the clauses when
   we simplified them before displaying them.
   It is currently useless. We keep it just in case.

  let red_rule_old_nb = List.rev (!red_rules) in
	
  let rec change_nb n = function
    | [] -> []
    | (hyp,cl,Rule(_,tag,hyp',cl',cons'),cons)::q ->
	(hyp,cl,Rule(n,tag,hyp',cl',cons'),cons)::(change_nb (n+1) q)
    | t::q -> t::(change_nb n q) in
	
  change_nb 1 red_rule_old_nb
	
  red_rule_old_nb
*)
