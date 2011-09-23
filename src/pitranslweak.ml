(*************************************************************
 *                                                           *
 *       Cryptographic protocol verifier                     *
 *                                                           *
 *       Bruno Blanchet and Xavier Allamigeon                *
 *                                                           *
 *       Copyright (C) INRIA, LIENS, MPII 2000-2010          *
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

(* Find the minimum phase in which choice is used *)

let rec has_choice = function
    Var _ -> false
  | FunApp(f,l) -> 
      (f.f_cat == Choice) || (List.exists has_choice l)

let min_choice_phase = ref max_int

let rec find_min_choice_phase current_phase = function
    Nil -> ()
  | Par(p,q) -> 
      find_min_choice_phase current_phase p;
      find_min_choice_phase current_phase q
  | Repl (p,_) ->
      find_min_choice_phase current_phase p
  | Restr(n,p,_) ->
      find_min_choice_phase current_phase p
  | Test(t1,t2,p,q,_) ->
      if has_choice t1 || has_choice t2 then
	begin
	  if current_phase < !min_choice_phase then
	    min_choice_phase := current_phase
	end;
      find_min_choice_phase current_phase p;
      find_min_choice_phase current_phase q
  | Input(tc,pat,p,_) ->
      if has_choice tc then 
	begin
	  if current_phase < !min_choice_phase then
	    min_choice_phase := current_phase
	end;
      find_min_choice_phase current_phase p
  | Output(tc,t,p,_) ->
      if has_choice tc || has_choice t then 
	begin
	  if current_phase < !min_choice_phase then
	    min_choice_phase := current_phase
	end;
      find_min_choice_phase current_phase p
      
  | Let(pat,t,p,q,_) ->
      if has_choice t then
	begin
	  if current_phase < !min_choice_phase then
	    min_choice_phase := current_phase
	end;
      find_min_choice_phase current_phase p;
      find_min_choice_phase current_phase q
  | LetFilter(vlist,f,p,q,_) ->
      user_error "Predicates are currently incompatible with non-interference.\n"
  | Event(_,p,_) ->
      find_min_choice_phase current_phase p
  | Insert(_,p,_) ->
      find_min_choice_phase current_phase p
  | Get(_,_,p,_) ->
      find_min_choice_phase current_phase p
  | Phase(n,p,_) ->
      find_min_choice_phase n p
      
(* Rule base *)

let nrule = ref 0
let red_rules = ref ([] : reduction list)

let mergelr = function
    Pred(p,[t1;t2]) as x ->
      begin
	match p.p_info with
	  [AttackerBin(i,t)] -> 
	    if i >= (!min_choice_phase) then x else
	    let att1_i = Param.get_pred (Attacker(i,t)) in
	    Terms.unify t1 t2;
	    Pred(att1_i, [t1])
	| [TableBin(i)] ->
	    if i >= (!min_choice_phase) then x else
	    let tbl1_i = Param.get_pred (Table(i)) in
	    Terms.unify t1 t2;
	    Pred(tbl1_i, [t1])
	| [InputPBin(i)] ->
	    if i >= (!min_choice_phase) then x else
	    let input1_i = Param.get_pred (InputP(i)) in
	    Terms.unify t1 t2;
	    Pred(input1_i, [t1])
	| [OutputPBin(i)] ->
	    if i >= (!min_choice_phase) then x else
	    let output1_i = Param.get_pred (OutputP(i)) in
	    Terms.unify t1 t2;
	    Pred(output1_i, [t1])
	| _ -> x
      end
  | Pred(p,[t1;t2;t3;t4]) as x ->
      begin
	match p.p_info with
	  [MessBin(i,t)] ->
	    if i >= (!min_choice_phase) then x else
	    let mess1_i = Param.get_pred (Mess(i,t)) in
	    Terms.unify t1 t3;
	    Terms.unify t2 t4;
	    Pred(mess1_i, [t1;t2])
	| _ -> x
      end
  | x -> x

let add_rule hyp concl constra tags =
  if !min_choice_phase > 0 then
    begin
      if !Terms.current_bound_vars != [] then
	Parsing_helper.internal_error "bound vars should be cleaned up (pitranslweak4)";
      try
	let hyp' = List.map mergelr hyp in
	let concl' = mergelr concl in
	let hyp'' = List.map Terms.copy_fact2 hyp' in
	let concl'' = Terms.copy_fact2 concl' in
	let constra'' = List.map Terms.copy_constra2 constra in
	let tags'' = 
	  match tags with
	    ProcessRule _ -> Parsing_helper.internal_error "ProcessRule should not be generated by pitranslweak"
	  | ProcessRule2(hsl, nl1, nl2) -> ProcessRule2(hsl, List.map Terms.copy_term2 nl1, List.map Terms.copy_term2 nl2)
	  | x -> x 
	in
	Terms.cleanup();	
	let constra'' = Rules.simplify_constra_list (concl''::hyp'') constra'' in
	red_rules := (hyp'', concl'', 
		      Rule (!nrule, tags'', hyp'', concl'', constra''), constra'') 
	  :: (!red_rules);
	incr nrule
      with Terms.Unify -> Terms.cleanup()
      |	Rules.FalseConstraint -> ()
    end
  else
    begin
      red_rules := (hyp, concl, Rule (!nrule, tags, hyp, concl, constra), constra) :: (!red_rules);
      incr nrule
    end

type transl_state = 
    { hypothesis : fact list; (* Current hypotheses of the rule *)
      constra : constraints list list; (* Current constraints of the rule *)
      unif : (term * term) list; (* Current unifications to do *)
      last_step_unif_left : (term * term) list; 
      last_step_unif_right : (term * term) list; 
      (* Unifications to do for the last group of destructor applications. 
         last_step_unif will be appended to unif before emitting clauses. 
	 The separation between last_step_unif and unif is useful only 
	 for non-interference. *)
      success_conditions_left : (term * term) list list ref option;
      success_conditions_right : (term * term) list list ref option;
      (* List of constraints that should be false for the evaluation
	 of destructors to succeed *)
      name_params_left : term list; (* List of parameters of names *)
      name_params_right : term list;
      name_params_meaning : string list;
      repl_count : int;
      input_pred : predicate;
      output_pred : predicate;
      cur_phase : int; (* Current phase *)
      hyp_tags : hypspec list
    }

let att_fact phase t1 t2 =
  Pred(Param.get_pred (AttackerBin(phase, Terms.get_term_type t1)), [t1; t2])
  
let mess_fact phase tc1 tm1 tc2 tm2 =
  Pred(Param.get_pred (MessBin(phase, Terms.get_term_type tm1)), [tc1;tm1;tc2;tm2])

let table_fact phase t1 t2 =
  Pred(Param.get_pred (TableBin(phase)), [t1;t2])

let output_rule { hypothesis = prev_input; constra = constra; unif = unif;
		  last_step_unif_left = lsu_l; last_step_unif_right = lsu_r;
		  name_params_left = name_params_left; 
		  name_params_right = name_params_right; hyp_tags = hyp_tags } 
    out_fact =
  try
     if (lsu_l != []) || (lsu_r != []) then
       Parsing_helper.internal_error "last_step_unif should have been appended to unif";
     if !Terms.current_bound_vars != [] then
       Parsing_helper.internal_error "bound vars should be cleaned up (pitranslweak2)";
      List.iter (fun (p1,p2) -> Terms.unify p1 p2) unif;
      let hyp = List.map Terms.copy_fact2 prev_input in
      let concl = Terms.copy_fact2 out_fact in
      let constra2 = List.map Terms.copy_constra2 constra in
      let name_params_left2 = List.map Terms.copy_term2 name_params_left in
      let name_params_right2 = List.map Terms.copy_term2 name_params_right in
      Terms.cleanup();
      begin
	try
	  add_rule hyp concl (Rules.simplify_constra_list (concl::hyp) constra2)
	    (ProcessRule2(hyp_tags, name_params_left2, name_params_right2))
	with Rules.FalseConstraint -> ()
      end
   with Terms.Unify -> 
      Terms.cleanup()

(* For non-interference *)

let start_destructor_group next_f occ cur_state =
  if (cur_state.last_step_unif_left != []) || (cur_state.last_step_unif_right != []) then
    Parsing_helper.internal_error "last_step_unif should have been appended to unif (start_destructor_group)";
  let sc_left = ref [] in
  let sc_right = ref [] in
  next_f { cur_state with
           success_conditions_left = Some sc_left;
           success_conditions_right = Some sc_right };
  if List.memq [] (!sc_left) && List.memq [] (!sc_right) then
    begin
      (* Both sides always succeed: the condition so that both side fail is false *)
      [[]]
    end
  else
    begin
      (* Get all vars in cur_state.hypothesis/unif/constra *)
      let var_list = ref [] in
      List.iter (Terms.get_vars_fact var_list) cur_state.hypothesis;
      List.iter (fun (t1,t2) -> Terms.get_vars var_list t1; Terms.get_vars var_list t2) cur_state.unif;
      List.iter (List.iter (Terms.get_vars_constra var_list)) cur_state.constra;
      (* Generalize all vars not in cur_state.hypothesis/unif/constra *)
      let l_l = List.map (List.map (fun (t1,t2) -> Neq(Terms.generalize_vars_not_in (!var_list) t1,
						       Terms.generalize_vars_not_in (!var_list) t2))) (!sc_left) in
      let l_r = List.map (List.map (fun (t1,t2) -> Neq(Terms.generalize_vars_not_in (!var_list) t1,
						       Terms.generalize_vars_not_in (!var_list) t2))) (!sc_right) in
      Terms.cleanup();
      (* When the phase is smaller than min_choice_phase, both sides behave the same way by definition
         so it is not necessary to generate the clauses below *)
      if cur_state.cur_phase >= !min_choice_phase then
	begin
          (* Left side succeeds, right side fails *)
	  List.iter (fun u_left ->
	    output_rule { cur_state with 
                          unif = u_left @ cur_state.unif;
                          constra = l_r @ cur_state.constra;
                          hyp_tags = TestUnifTag2(occ):: cur_state.hyp_tags }
	      (Pred(Param.bad_pred, []))
	      ) (!sc_left);
          (* Right side succeeds, left side fails *)
          List.iter (fun u_right ->
	    output_rule { cur_state with 
                          unif = u_right @ cur_state.unif;
		          constra = l_l @ cur_state.constra;
                          hyp_tags = TestUnifTag2(occ):: cur_state.hyp_tags }
	      (Pred(Param.bad_pred, []))
	      ) (!sc_right)
	end;
      (* Conditions so that both sides fail *)
      l_l @ l_r
    end

let start_destructor_group_i next_f occ cur_state =
  ignore (start_destructor_group next_f occ cur_state)

let end_destructor_group next_f cur_state =
  next_f { cur_state with 
	   unif = cur_state.last_step_unif_right @ cur_state.last_step_unif_left @ cur_state.unif;
	   last_step_unif_left = [];
	   last_step_unif_right = [];
	   success_conditions_left = None;
           success_conditions_right = None };
  begin
    match cur_state.success_conditions_left with
      None -> internal_error "Group ended but not started"
    | Some r -> r:= cur_state.last_step_unif_left :: (!r)
  end;
  begin
    match cur_state.success_conditions_right with
      None -> internal_error "Group ended but not started"
    | Some r -> r:= cur_state.last_step_unif_right :: (!r)
  end

(* Functions that modify last_step_unif, and that should
   therefore be followed by a call to end_destructor_group 

   transl_term
   transl_term_list
   transl_term_incl_destructor
   transl_term_list_incl_destructor
   transl_pat

*)

(* Translate term *)

(* next_f takes a state and two patterns as parameter *)
let rec transl_term next_f cur_state = function 
    Var v -> 
      begin
	match v.link with
          TLink (FunApp(_, [t1;t2])) -> next_f cur_state t1 t2
	| _ -> internal_error "unexpected link in transl_term"
      end
  | FunApp(f,l) ->
      let transl_red red_rules =
        transl_term_list (fun cur_state1 patlist1 patlist2 -> 
	  if cur_state.cur_phase < !min_choice_phase then
	    List.iter (fun red_rule ->
              let (left_list1, right1) = Terms.copy_red red_rule in
              let (left_list2, right2) = Terms.copy_red red_rule in
	      next_f { cur_state1 with 
                       last_step_unif_left = List.fold_left2(fun accu_unif pat left ->
			 (pat,left)::accu_unif) cur_state1.last_step_unif_left patlist1 left_list1;
		       last_step_unif_right = List.fold_left2(fun accu_unif pat left ->
			 (pat,left)::accu_unif) cur_state1.last_step_unif_right patlist2 left_list2} right1 right2
		) red_rules
	  else
	    List.iter (fun red_rule1 ->
	      List.iter (fun red_rule2 ->
		let (left_list1, right1) = Terms.copy_red red_rule1 in
		let (left_list2, right2) = Terms.copy_red red_rule2 in
		next_f { cur_state1 with 
                         last_step_unif_left = List.fold_left2(fun accu_unif pat left ->
			   (pat,left)::accu_unif) cur_state1.last_step_unif_left patlist1 left_list1;
		         last_step_unif_right = List.fold_left2(fun accu_unif pat left ->
			   (pat,left)::accu_unif) cur_state1.last_step_unif_right patlist2 left_list2} right1 right2
		  ) red_rules
	        ) red_rules
	    ) cur_state l
      in	
      match f.f_cat with
	Name n ->  
	  begin
            match n.prev_inputs with
              Some (FunApp(_, [t1;t2])) -> next_f cur_state t1 t2
            | _ -> internal_error "unexpected prev_inputs in transl_term"
	  end
      | Tuple -> 
          transl_term_list (fun cur_state1 patlist1 patlist2 -> 
	    next_f cur_state1 (FunApp(f, patlist1)) (FunApp(f, patlist2))) cur_state l
      | Eq red_rules ->
	  let vars1 = Terms.var_gen (fst f.f_type) in
	  transl_red ((vars1, FunApp(f, vars1)) :: red_rules)
      | Red red_rules ->
	  transl_red red_rules
      |	Choice ->
	  begin
	    match l with
	      [t1;t2] ->
		transl_term (fun cur_state1 t11 t12 ->
		  transl_term (fun cur_state2 t21 t22 ->
		    next_f { cur_state2 with last_step_unif_left = cur_state1.last_step_unif_left } t11 t22
		    ) { cur_state1 with last_step_unif_right = cur_state.last_step_unif_right } t2
		  ) cur_state t1
	    | _ -> Parsing_helper.internal_error "Choice should have two arguments"
	  end
      | _ ->
           Parsing_helper.internal_error "function symbols of these categories should not appear in input terms"


(* next_f takes a state and two lists of patterns as parameter *)
and transl_term_list next_f cur_state = function
    [] -> next_f cur_state [] []
  | (a::l) -> 
      transl_term (fun cur_state1 p1 p2 ->
	transl_term_list (fun cur_state2 patlist1 patlist2 -> 
	  next_f cur_state2 (p1::patlist1) (p2::patlist2)) cur_state1 l) cur_state a

let rec check_several_types = function
    Var _ -> false
  | FunApp(f,l) ->
      (List.exists check_several_types l) || 
      (if !Param.eq_in_names then
	 (* Re-allow an old setting, which was faster on some examples *)
	 match f.f_cat with
       	   Red rules -> List.length rules > 1
	 | Eq rules -> List.length rules > 0
	 | _ -> false
      else
	 match f.f_initial_cat with
       	   Red rules -> List.length rules > 1
         | _ -> false)

let transl_term_incl_destructor f t cur_state =
  let may_have_several_types = check_several_types t in
  transl_term (fun cur_state1 pat1 pat2 ->
    if may_have_several_types then
      f pat1 pat2 { cur_state1 with 
                    name_params_left = pat1::cur_state1.name_params_left;
		    name_params_right = pat2::cur_state1.name_params_right;
                    name_params_meaning = "" :: cur_state1.name_params_meaning }
    else
      f pat1 pat2 cur_state1
    ) cur_state t

(*
let transl_term_list_incl_destructor f tl cur_state =
  let may_have_several_types = List.exists check_several_types tl in
  transl_term_list (fun cur_state1 patlist1 patlist2 ->
    if may_have_several_types then
      f patlist1 patlist2 { cur_state1 with 
			    name_params_left = patlist1 @ cur_state1.name_params_left;
			    name_params_right = patlist2 @ cur_state1.name_params_right;
			    name_params_meaning = (List.map (fun _ -> "") patlist1) @ cur_state1.name_params_meaning }
    else
      f patlist1 patlist2 cur_state1
    ) cur_state tl
*)

(* Translate pattern *)

let rec transl_pat put_var f pat pat1' pat2' cur_state =
  match pat with
    PatVar b ->
      b.link <- TLink (FunApp(Param.choice_fun b.btype, [pat1'; pat2']));
      f (if put_var then
	  { cur_state with 
	    name_params_left = pat1' :: cur_state.name_params_left;
	    name_params_right = pat2' :: cur_state.name_params_right;
            name_params_meaning = b.sname :: cur_state.name_params_meaning }
         else
	  cur_state);
      b.link <- NoLink
  | PatTuple (fsymb,patlist) ->
      let patlist1' = List.map Reduction_helper.new_var_pat patlist in
      let patlist2' = List.map Reduction_helper.new_var_pat patlist in
      let pat21 = FunApp(fsymb, patlist1') in
      let pat22 = FunApp(fsymb, patlist2') in
      transl_pat_list put_var f patlist patlist1' patlist2'
	{ cur_state with 
	  last_step_unif_left = (pat1', pat21)::cur_state.last_step_unif_left;
	  last_step_unif_right = (pat2', pat22)::cur_state.last_step_unif_right
	};
  | PatEqual t ->
      transl_term_incl_destructor (fun pat1 pat2 cur_state ->
	f { cur_state with 
	    last_step_unif_left = (pat1,pat1')::cur_state.last_step_unif_left;
	    last_step_unif_right = (pat2,pat2')::cur_state.last_step_unif_right;
	  }
	    ) t cur_state

and transl_pat_list put_var f patlist patlist1' patlist2' cur_state =
  match (patlist, patlist1', patlist2') with
    ([],[],[]) -> f cur_state
  | (p::pl, p1'::pl1', p2'::pl2') ->
      transl_pat_list put_var (transl_pat put_var f p p1' p2') pl pl1' pl2' cur_state
  | _ -> internal_error "not same length in transl_pat_list"
      

(* Translate process *)

let rec transl_process cur_state = function
   Nil -> ()
 | Par(p,q) -> transl_process cur_state p;
               transl_process cur_state q
 | Repl (p,occ) -> 
     (* Always introduce session identifiers ! *)
     let v1 = Terms.new_var "sid" Param.sid_type in
     transl_process { cur_state with
                      repl_count = cur_state.repl_count + 1;
		      name_params_left = (Var v1) :: cur_state.name_params_left;
		      name_params_right = (Var v1) :: cur_state.name_params_right;
                      name_params_meaning = ("!" ^ (string_of_int (cur_state.repl_count+1))) :: cur_state.name_params_meaning;
                      hyp_tags = (ReplTag(occ, List.length cur_state.name_params_left)) :: cur_state.hyp_tags } p
 | Restr(n,p,occ) -> 
     begin
     match n.f_cat with
       Name r -> 
	 let ntype = List.map Terms.get_term_type cur_state.name_params_left in
	 if fst n.f_type == Param.tmp_type then 
	   begin
	     n.f_type <- ntype, snd n.f_type;
	     r.prev_inputs_meaning <- cur_state.name_params_meaning
	   end
	 else if not (Terms.eq_lists (fst n.f_type) ntype) then
	   internal_error ("Name " ^ n.f_name ^ " has bad arity");
         r.prev_inputs <- Some (FunApp(Param.choice_fun (snd n.f_type), [ FunApp(n, cur_state.name_params_left); 
									  FunApp(n, cur_state.name_params_right)]));
         transl_process cur_state p;
         r.prev_inputs <- None
     | _ -> internal_error "A restriction should have a name as parameter"
     end

 | Test(t1,t2,p,q,occ) ->
     start_destructor_group_i (fun cur_state ->
       transl_term_incl_destructor (fun pat1_l pat1_r cur_state1 ->
	 transl_term_incl_destructor (fun pat2_l pat2_r cur_state2 ->
           end_destructor_group (fun cur_state3 ->
	     output_rule { cur_state3 with 
                           unif = (pat1_l, pat2_l) :: cur_state3.unif;
                           constra = [Neq(pat1_r,pat2_r)] :: cur_state3.constra;
                           hyp_tags = TestUnifTag2(occ) :: cur_state3.hyp_tags } (Pred(Param.bad_pred, []));
	     output_rule { cur_state3 with 
                           unif = (pat1_r, pat2_r) :: cur_state3.unif;
                           constra = [Neq(pat1_l,pat2_l)] :: cur_state3.constra;
                           hyp_tags = TestUnifTag2(occ) :: cur_state3.hyp_tags } (Pred(Param.bad_pred, []));
             transl_process { cur_state3 with 
                              unif = (pat1_l,pat2_l) :: (pat2_r,pat2_r) :: cur_state3.unif;
                              hyp_tags = (TestTag occ) :: cur_state3.hyp_tags } p;
	     transl_process { cur_state3 with 
                              constra = [Neq(pat1_l, pat2_l)] :: [Neq(pat1_r,pat2_r)] :: cur_state3.constra;
                              hyp_tags = (TestTag occ) :: cur_state3.hyp_tags } q
               ) cur_state2
	     ) t2 cur_state1
	   ) t1 cur_state
	 ) occ cur_state

 | Input(tc,pat,p,occ) ->
      let v1 = Reduction_helper.new_var_pat pat in
      let v2 = Reduction_helper.new_var_pat pat in
      begin
        match tc with
          FunApp({ f_cat = Name _; f_private = false },_) when !Param.active_attacker ->
	    start_destructor_group_i (fun cur_state ->
	      transl_pat true (
	        end_destructor_group (fun cur_state1 -> 
		  transl_process cur_state1 p)
		)
		pat v1 v2 cur_state
		) occ { cur_state with 
                        hypothesis = (att_fact cur_state.cur_phase v1 v2) :: cur_state.hypothesis;
                        hyp_tags = (InputTag(occ)) :: cur_state.hyp_tags }
	    (* When the channel is a public name, and the same name a on both sides,
               generating h -> input2:a,a is useless since
	       attacker2:a,a and attacker2:x,x' -> input2:x,x' *)
        | _ -> 
	    start_destructor_group_i (fun cur_state ->
	      transl_term_incl_destructor (fun pat1 pat2 cur_state1 ->
		end_destructor_group (fun cur_state2 ->
		  start_destructor_group_i (fun cur_state2 ->
	      	    transl_pat true (end_destructor_group (fun cur_state3 -> 
                      transl_process cur_state3 p)) pat v1 v2 cur_state2
		      ) occ { cur_state2 with 
                              hypothesis = (mess_fact cur_state.cur_phase pat1 v1 pat2 v2) :: cur_state2.hypothesis;
                              hyp_tags = (InputTag(occ)) :: cur_state2.hyp_tags };
                  output_rule { cur_state2 with
                                hyp_tags = (InputPTag(occ)) :: cur_state2.hyp_tags }
		    (Pred(cur_state.input_pred, [pat1; pat2]))
		    ) cur_state1
		  ) tc cur_state
		) occ cur_state
      end

 | Output(tc,t,p,occ) ->
      begin
        match tc with 
          FunApp({ f_cat = Name _; f_private = false },_) when !Param.active_attacker -> 
	    (* Same remark as for input *)
	    start_destructor_group_i (fun cur_state ->
	      transl_term (fun cur_state1 pat1 pat2 ->
		end_destructor_group (fun cur_state2 ->
                  output_rule { cur_state2 with hyp_tags = (OutputTag occ) :: cur_state2.hyp_tags }
		    (att_fact cur_state.cur_phase pat1 pat2)
		    ) cur_state1
		  ) cur_state t
		) occ cur_state
        | _ -> 
	    start_destructor_group_i (fun cur_state ->
	      transl_term (fun cur_state1 patc1 patc2 ->
                transl_term (fun cur_state2 pat1 pat2 ->
                  end_destructor_group (fun cur_state3 ->
                    output_rule { cur_state3 with
                                  hyp_tags = (OutputPTag occ) :: cur_state3.hyp_tags }
		      (Pred(cur_state.output_pred, [patc1; patc2]));
                    output_rule { cur_state3 with
                                  hypothesis = cur_state3.hypothesis;
                                  hyp_tags = (OutputTag occ) :: cur_state2.hyp_tags }
		      (mess_fact cur_state.cur_phase patc1 pat1 patc2 pat2)
                      ) cur_state2
                    ) cur_state1 t
		  ) cur_state tc
		) occ cur_state
      end;
      transl_process { cur_state with
                       hyp_tags = (OutputTag occ) :: cur_state.hyp_tags } p

 | Let(pat,t,p,p',occ) ->
     let failure_conditions =
     start_destructor_group (fun cur_state ->
       transl_term_incl_destructor (fun pat1 pat2 cur_state1 ->
	 transl_pat false (end_destructor_group (fun cur_state2 -> transl_process cur_state2 p))
	   pat pat1 pat2 cur_state1
	   ) t cur_state
	 ) occ { cur_state with hyp_tags = (LetTag occ) :: cur_state.hyp_tags }
     in
     transl_process { cur_state with
                      constra = failure_conditions @ cur_state.constra;
                      hyp_tags = (LetTag occ) :: cur_state.hyp_tags } p'

 | LetFilter(vlist,f,p,q,occ) ->
       user_error "Predicates are currently incompatible with non-interference.\n"

 | Event(_, p, _) ->
     transl_process cur_state p

 | Insert(t,p,occ) ->
     start_destructor_group_i (fun cur_state ->
       transl_term (fun cur_state1 pat1 pat2 ->
	 end_destructor_group (fun cur_state2 ->
           output_rule { cur_state2 with hyp_tags = (InsertTag occ) :: cur_state2.hyp_tags }
	     (table_fact cur_state.cur_phase pat1 pat2)
	     ) cur_state1
	   ) cur_state t
	 ) occ cur_state;
     transl_process { cur_state with
                      hyp_tags = (InsertTag occ) :: cur_state.hyp_tags } p

 | Get(pat,t,p,occ) ->
      let v1 = Reduction_helper.new_var_pat pat in
      let v2 = Reduction_helper.new_var_pat pat in
      start_destructor_group_i (fun cur_state ->
	transl_pat true (fun cur_state1 ->
	  transl_term (fun cur_state2 patt1 patt2 ->
	    end_destructor_group (fun cur_state3 -> transl_process cur_state3 p)
	      { cur_state2 with
                last_step_unif_left = (patt1, FunApp(Terms.true_cst, [])) :: cur_state2.last_step_unif_left;
                last_step_unif_right = (patt2, FunApp(Terms.true_cst, [])) :: cur_state2.last_step_unif_right }
	      ) cur_state1 t
	    ) pat v1 v2 cur_state
	  ) occ { cur_state with 
                  hypothesis = (table_fact cur_state.cur_phase v1 v2) :: cur_state.hypothesis;
                  hyp_tags = (GetTag(occ)) :: cur_state.hyp_tags }

 | Phase(n,p,_) ->
     transl_process { cur_state with 
                      input_pred = Param.get_pred (InputPBin(n));
                      output_pred = Param.get_pred (OutputPBin(n));
                      cur_phase = n } p

let rules_for_red f phase red_rules =
  let res_pred = Param.get_pred (AttackerBin(phase, snd f.f_type)) in
  if phase < !min_choice_phase then 
    (* Optimize generation when no choice in the current phase *)
    List.iter (fun red1 ->
      let (hyp1, concl1) = Terms.copy_red red1 in
      add_rule (List.map (fun t -> att_fact phase t t) hyp1)
	(att_fact phase concl1 concl1) []
	(Apply(Func(f), res_pred))
	) red_rules
  else
    List.iter (fun red1 ->
      List.iter (fun red2 ->
	let (hyp1, concl1) = Terms.copy_red red1 in
	let (hyp2, concl2) = Terms.copy_red red2 in
	add_rule (List.map2 (att_fact phase) hyp1 hyp2)
	  (att_fact phase concl1 concl2) []
	  (Apply(Func(f), res_pred))
	  ) red_rules
	) red_rules

let rules_for_function phase _ f =
   if not f.f_private then
     let res_pred = Param.get_pred (AttackerBin(phase, snd f.f_type)) in
   match f.f_cat with
     Eq red_rules -> 
	let vars1 = Terms.var_gen (fst f.f_type) in
        rules_for_red f phase ((vars1, FunApp(f, vars1)) :: red_rules)
   | Red red_rules ->
       rules_for_red f phase red_rules;
       List.iter (fun red ->
	  let (hyp, _) = Terms.copy_red red in
	  let vlist = List.map Terms.new_var_def (List.map Terms.get_term_type hyp) in
	  let make_constra red =
	    let (hyp, _) = Terms.copy_red red in
	    if !Terms.current_bound_vars != [] then
	      Parsing_helper.internal_error "bound vars should be cleaned up (pitranslweak3)";
	    let hyp' = List.map (Terms.generalize_vars_not_in []) hyp in
	    Terms.cleanup();
	    List.map2 (fun v t -> Neq(v,t)) vlist hyp'
	  in  
	  add_rule 
            (List.map2 (att_fact phase) hyp vlist)
	    (Pred(Param.bad_pred, []))
	    (List.map make_constra red_rules)
	    (TestApply(Func(f), res_pred));

	  let (hyp, _) = Terms.copy_red red in
	  let vlist = List.map Terms.new_var_def (List.map Terms.get_term_type hyp) in
	  let make_constra red =
	    let (hyp, _) = Terms.copy_red red in
	    if !Terms.current_bound_vars != [] then
	      Parsing_helper.internal_error "bound vars should be cleaned up (pitranslweak3)";
	    let hyp' = List.map (Terms.generalize_vars_not_in []) hyp in
	    Terms.cleanup();
	    List.map2 (fun v t -> Neq(v,t)) vlist hyp'
	  in  
	  add_rule 
            (List.map2 (att_fact phase) vlist hyp)
	    (Pred(Param.bad_pred, []))
	    (List.map make_constra red_rules)
	    (TestApply(Func(f), res_pred))

		  ) red_rules
   | Tuple -> 
	(* For tuple constructor *)
	let vars1 = Terms.var_gen (fst f.f_type) in
	let vars2 = Terms.var_gen (fst f.f_type) in
	add_rule (List.map2 (att_fact phase) vars1 vars2)
	  (att_fact phase (FunApp(f, vars1)) (FunApp(f, vars2))) []
	  (Apply(Func(f), res_pred));

	(* For corresponding projections *)
	for n = 0 to (List.length (fst f.f_type))-1 do
	  let vars1 = Terms.var_gen (fst f.f_type) in
	  let vars2 = Terms.var_gen (fst f.f_type) in
	  let v1 = List.nth vars1 n in
	  let v2 = List.nth vars2 n in
	  add_rule [att_fact phase (FunApp(f, vars1)) (FunApp(f, vars2))]
	    (att_fact phase v1 v2) []
	    (Apply(Proj(f,n),res_pred))
	done;

	let vars1 = Terms.var_gen (fst f.f_type) in
	let v = Terms.new_var_def (snd f.f_type) in
	let gvars1 = List.map (fun ty -> FunApp(Terms.new_gen_var ty,[])) (fst f.f_type) in
	add_rule [att_fact phase (FunApp(f, vars1)) v]
	  (Pred(Param.bad_pred, [])) [[Neq(v, FunApp(f, gvars1))]] 
	  (TestApply(Proj(f,0),res_pred));
	  
	let vars1 = Terms.var_gen (fst f.f_type) in
	let v = Terms.new_var_def (snd f.f_type) in
	let gvars1 = List.map (fun ty -> FunApp(Terms.new_gen_var ty,[])) (fst f.f_type) in
	add_rule [att_fact phase v (FunApp(f, vars1))]
	  (Pred(Param.bad_pred, [])) [[Neq(v, FunApp(f, gvars1))]] 
	  (TestApply(Proj(f,0),res_pred))

    | _ -> ()

let transl_attacker phase =
  (* The attacker can apply all functions, including tuples *)
  Hashtbl.iter (rules_for_function phase) Param.fun_decls;
  Hashtbl.iter (rules_for_function phase) Terms.tuple_table;

  List.iter (fun t ->
    let att_pred = Param.get_pred (AttackerBin(phase,t)) in
    let mess_pred = Param.get_pred (MessBin(phase,t)) in

    (* The attacker has any message sent on a channel he has *)
    let v1 = Terms.new_var_def t in
    let vc1 = Terms.new_var_def Param.channel_type in
    let v2 = Terms.new_var_def t in
    let vc2 = Terms.new_var_def Param.channel_type in
    add_rule [Pred(mess_pred, [vc1; v1; vc2; v2]); att_fact phase vc1 vc2]
      (Pred(att_pred, [v1; v2])) [] (Rl(att_pred, mess_pred));

    if (!Param.active_attacker) then
      begin
        (* The attacker can send any message he has on any channel he has *)
	let v1 = Terms.new_var_def t in
	let vc1 = Terms.new_var_def Param.channel_type in
	let v2 = Terms.new_var_def t in
	let vc2 = Terms.new_var_def Param.channel_type in
	add_rule [att_fact phase vc1 vc2; Pred(att_pred, [v1; v2])]
          (Pred(mess_pred, [vc1; v1; vc2; v2])) [] (Rs(att_pred, mess_pred))
      end;

    (* Clauses for equality *)
    let v = Terms.new_var_def t in
    add_rule [] (Pred(Param.get_pred (Equal(t)), [v;v])) [] LblEq
	) (if !Param.ignore_types then [Param.any_type] else !Param.all_types);

  if phase >= !min_choice_phase then 
    begin
      let att_pred = Param.get_pred (AttackerBin(phase,Param.channel_type)) in
      let input_pred = Param.get_pred (InputPBin(phase)) in
      let output_pred = Param.get_pred (OutputPBin(phase)) in
 
      (* The attacker can do communications *)
      let vc1 = Terms.new_var_def Param.channel_type in
      let vc2 = Terms.new_var_def Param.channel_type in
      add_rule [Pred(att_pred, [vc1; vc2])] (Pred(input_pred, [vc1;vc2])) [] (Ri(att_pred, input_pred));
      let vc1 = Terms.new_var_def Param.channel_type in
      let vc2 = Terms.new_var_def Param.channel_type in
      add_rule [Pred(att_pred, [vc1; vc2])] (Pred(output_pred, [vc1; vc2])) [] (Ro(att_pred, output_pred));

      (* Check communications do not reveal secrets *)
      let vc = Terms.new_var_def Param.channel_type in
      let vc1 = Terms.new_var_def Param.channel_type in
      let vc2 = Terms.new_var_def Param.channel_type in
      add_rule [Pred(input_pred, [vc; vc1]); 
		 Pred(output_pred, [vc; vc2])] 
	 (Pred(Param.bad_pred, [])) [[Neq(vc1,vc2)]] 
	 (TestComm(input_pred, output_pred));
	   
      let vc = Terms.new_var_def Param.channel_type in
      let vc1 = Terms.new_var_def Param.channel_type in
      let vc2 = Terms.new_var_def Param.channel_type in
      add_rule [Pred(input_pred, [vc1; vc]); 
		 Pred(output_pred, [vc2; vc])] 
	(Pred(Param.bad_pred, [])) [[Neq(vc1,vc2)]] 
	(TestComm(input_pred, output_pred))

     end



(* Global translation *)

let transl p = 
  Rules.reset ();
  Reduction_helper.main_process := p;
  nrule := 0;
  red_rules := [];
  (*
  List.iter (fun (hyp1, concl1, constra1, tag1) -> 
    TermsEq.close_rule_destr_eq (fun (hyp, concl, constra) ->
      add_rule hyp concl constra tag1) (hyp1, concl1, constra1))
    (!Pisyntax.red_rules);
    *)
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
      let att_i = Param.get_pred (AttackerBin(i,t)) in
      if i < !min_choice_phase then
	begin
	(* Phase coded by unary predicates *)
	  let v = Terms.new_var Param.def_var_name t in
	  let att_i = Param.get_pred (Attacker(i,t)) in
	  Selfun.add_no_unif (att_i, [FVar v]) Selfun.never_select_weight
	end
      else
	begin
	(* Phase coded by binary predicates *)
	  let v1 = Terms.new_var Param.def_var_name t in
	  let v2 = Terms.new_var Param.def_var_name t in
	  Selfun.add_no_unif (att_i, [FVar v1; FVar v2]) Selfun.never_select_weight
	end;
      if i > 0 then
	let w1 = Terms.new_var_def t in
	let w2 = Terms.new_var_def t in
	let att_im1 = Param.get_pred (AttackerBin(i-1,t)) in
	add_rule [Pred(att_im1, [w1; w2])] (Pred(att_i, [w1; w2])) [] PhaseChange
	  ) (if !Param.ignore_types || !Param.untyped_attacker then [Param.any_type] else !Param.all_types);
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
        add_rule [] (att_fact 0 (FunApp(ch, [])) (FunApp(ch, []))) [] Init) (!Param.freenames);

  List.iter (fun t ->
    (* The attacker can create new names *)
    let v1 = Terms.new_var_def Param.sid_type in
    let new_name_fun = Terms.new_name_fun t in
    add_rule [] (att_fact 0 (FunApp(new_name_fun, [v1])) (FunApp(new_name_fun, [v1]))) 
      [] (Rn (Param.get_pred (AttackerBin(0, t))));

    (* Rules that derive bad are necessary only in the last phase.
       Previous phases will get them by attacker'_i(x,y) -> attacker'_{i+1}(x,y) *)

    let att_pred = Param.get_pred (AttackerBin(!Param.max_used_phase, t)) in

    (* The attacker can perform equality tests *)
    let v1 = Terms.new_var_def t in
    let v2 = Terms.new_var_def t in
    let v3 = Terms.new_var_def t in
    add_rule [Pred(att_pred, [v1; v2]); Pred(att_pred, [v1; v3])]
      (Pred(Param.bad_pred, [])) [[Neq(v2,v3)]] (TestEq(att_pred));

    let v1 = Terms.new_var_def t in
    let v2 = Terms.new_var_def t in
    let v3 = Terms.new_var_def t in
    add_rule [Pred(att_pred, [v2; v1]); Pred(att_pred, [v3; v1])]
      (Pred(Param.bad_pred, [])) [[Neq(v2,v3)]] (TestEq(att_pred))

      ) (if !Param.ignore_types || !Param.untyped_attacker then [Param.any_type] else !Param.all_types);

   List.iter (fun ch -> match ch.f_cat with
     Name r -> r.prev_inputs <- Some (FunApp(Param.choice_fun (snd ch.f_type), [FunApp(ch, []); FunApp(ch, [])]))
   | _ -> internal_error "should be a name 1")
	(!Param.freenames);
   transl_process 
     { hypothesis = []; constra = []; unif = []; 
       last_step_unif_left = []; last_step_unif_right = [];
       success_conditions_left = None; success_conditions_right = None;  
       name_params_left = []; name_params_right = []; 
       name_params_meaning = [];
       repl_count = 0; 
       input_pred = Param.get_pred (InputPBin(0));
       output_pred = Param.get_pred (OutputPBin(0));
       cur_phase = 0;
       hyp_tags = [] } p;
   List.iter (fun ch -> match ch.f_cat with
                          Name r -> r.prev_inputs <- None
                        | _ -> internal_error "should be a name 2")
        (!Param.freenames);

  List.iter (function 
      QFact({ p_info = [Attacker(i,ty)] },[t]) ->
	(* For attacker: not declarations, the not declaration is also
	   valid in previous phases, because of the implication
	   attacker_p(i):x => attacker_p(i+1):x
	   Furthermore, we have to translate unary to binary not declarations 
	   *)
	for j = 0 to i do
	  if j < !min_choice_phase then
		(* Phase coded by unary predicate, since it does not use choice *)
	    let att_j = Param.get_pred (Attacker(j,ty)) in
	    Rules.add_not(Pred(att_j,[t]))
	  else
		(* Phase coded by binary predicate *)
	    let att2_j = Param.get_pred (AttackerBin(j,ty)) in
	    Rules.add_not(Pred(att2_j,[t;t]))
	done
    | QFact({ p_info = [Mess(i,ty)] } as p,[t1;t2]) ->
	(* translate unary to binary not declarations *)
	if i < !min_choice_phase then
		(* Phase coded by unary predicate, since it does not use choice *)
	  Rules.add_not(Pred(p, [t1;t2]))
	else
		(* Phase coded by binary predicate *)
	  let mess2_i = Param.get_pred (MessBin(i,ty)) in
	  Rules.add_not(Pred(mess2_i,[t1;t2;t1;t2]))
    | _ -> Parsing_helper.user_error "The only allowed facts in \"not\" declarations are attacker: and mess: predicates (for process equivalences, user-defined predicates are forbidden).\n"
	  ) (if !Param.typed_frontend then Pitsyntax.get_not() else Pisyntax.get_not());

  List.iter (function (f,n) ->
    (* translate unary to binary nounif declarations *)
    match f with
      ({ p_info = [Attacker(i,ty)] }, [t]) -> 
	if i < !min_choice_phase then
		(* Phase coded by unary predicate, since it does not use choice *)
	  Selfun.add_no_unif f n
	else
		(* Phase coded by binary predicate *)
	  let att2_i = Param.get_pred (AttackerBin(i,ty)) in
	  Selfun.add_no_unif (att2_i, [t;t]) n
    | ({ p_info = [Mess(i,ty)] }, [t1;t2]) ->
	if i < !min_choice_phase then
		(* Phase coded by unary predicate, since it does not use choice *)
	  Selfun.add_no_unif f n
	else
		(* Phase coded by binary predicate *)
	  let mess2_i = Param.get_pred (MessBin(i,ty)) in
	  Selfun.add_no_unif (mess2_i,[t1;t2;t1;t2]) n
    | _ -> Parsing_helper.user_error "The only allowed facts in \"nounif\" declarations are attacker: and mess: predicates (for process equivalences, user-defined predicates are forbidden).\n"
      ) (if !Param.typed_frontend then Pitsyntax.get_nounif() else Pisyntax.get_nounif());

  List.rev (!red_rules)

