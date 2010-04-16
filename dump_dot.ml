(* Kaspar Rohrer, Wed Apr 14 01:57:49 CEST 2010 *)

module HT = Hashtbl.Make(Value)

let string_with_buffer n =
  let b = Buffer.create n in
    ( fun f ->
	Buffer.clear b;
	f b;
	Buffer.contents b
    )

open Format

let (|>>) a b = b a

type dot_attrs = (string * string) list

type follow = src:Obj.t -> field:int -> dst:Obj.t -> bool

class type context =
object
  method graph_attrs : dot_attrs
  method all_nodes_attrs : dot_attrs
  method all_edges_attrs : dot_attrs
  method node_attrs : ?root:bool -> Obj.t -> dot_attrs
  method edge_attrs : src:Obj.t -> field:int -> dst:Obj.t -> dot_attrs

  method should_inline : Obj.t -> bool
  method should_follow_edge : src:Obj.t -> field:int -> dst:Obj.t -> bool
  method max_fields_for_node : Obj.t -> int
end

(*----------------------------------------------------------------------------*)

(* See http://www.graphviz.org/doc/info/colors.html for more info. *)

let attrs_colorscheme_for_value ?(k=2.) ?lower ?upper color_scheme n r attrs =
  let f2i = int_of_float and i2f = float_of_int in
  let lower = match lower with None -> 1 | Some l -> l in
  let upper = match upper with None -> n - 1 | Some u -> u in
    (* Arcsin seems like a good choice here, it starts of almost
       linear, but the derivative seems to decay at an exponential
       rate. k adjusts the shape in that approximates the distance
       between the first two colors. *)
  let arcsinh x = log (x +. sqrt (x*.x +. 1.)) in
  let x = i2f (Value.heap_words r) in
  let y = f2i (arcsinh ( x /. k )) in
  let i = min upper (y + lower) in
  let attrs = 
    ("colorscheme", color_scheme ^ string_of_int n)
    :: ("fillcolor", string_of_int i)
    :: ("color", string_of_int n)
    :: attrs
  in
    if i = n then
      ("fontcolor", "white") :: attrs
    else
      attrs

let attrs_for_value r attrs =
  match Value.tag r with
    | Value.Infix
    | Value.Forward ->
	(* attrs_colorscheme_for_value "purples" 9 r attrs *)
	attrs_colorscheme_for_value ~lower:2 "ylorbr" 3 r attrs

    | Value.Lazy
    | Value.Closure ->
	attrs_colorscheme_for_value ~k:1.2 ~lower:2 "rdpu" 9 r attrs

    | Value.Object ->
	attrs_colorscheme_for_value ~k:1.2 ~lower:4 "purples" 9 r attrs

    | Value.Block ->
	attrs_colorscheme_for_value ~lower:2 "blues" 9 r attrs

    | Value.Int
    | Value.String
    | Value.Double
    | Value.Double_array ->
  	attrs_colorscheme_for_value ~lower:2 "bugn" 9 r attrs

    | Value.Custom when Value.custom_is_int r -> (
	match Value.custom_value r with
	  | Value.Custom_nativeint _
	  | Value.Custom_int32 _
	  | Value.Custom_int64 _ ->
  	      attrs_colorscheme_for_value ~lower:2 "bugn" 9 r attrs
	  | _ ->
	      attrs_colorscheme_for_value ~k:1.0 ~lower:5 "reds" 9 r attrs )

    | Value.Out_of_heap
    | Value.Unaligned
    | Value.Abstract
    | Value.Custom ->
	attrs_colorscheme_for_value ~k:1.0 ~lower:5 "reds" 9 r attrs

let label_of_value context r =
  let bprint_fields b n bf =
    let max_fields = context#max_fields_for_node r in
    let n' = min max_fields n in
    let cutoff = if n' = max_fields then n' - 1 else max_int in
      for i = 0 to n' - 1 do
	Buffer.add_string b "| ";
	if i = cutoff then
	  Buffer.add_string b "..."
	else
	  Buffer.add_string b (bf i)
      done
  in
  let bprint b =
    Buffer.add_string b (Value.description r);
    match Value.tag r with
      | _ when Obj.tag r < Obj.no_scan_tag ->
	  let n = Obj.size r in
	    bprint_fields b n (fun i -> Value.abbrev (Obj.field r i))

      | Value.Double_array ->
	  assert (Obj.tag r = Obj.double_array_tag);
	  let a : float array = Obj.magic r in
	  let n = Array.length a in
	    bprint_fields b n (fun i -> string_of_float a.(i))

      | Value.Custom | Value.Abstract ->
	  assert (Obj.tag r = Obj.custom_tag || Obj.tag r = Obj.abstract_tag);
	  let n = Obj.size r in
	    bprint_fields b n (fun _ -> Value.mnemonic_unknown)

      | Value.String ->
	  assert (Obj.tag r = Obj.string_tag);
	  let nbytes = Sys.word_size / 8 in 
	  let lsub = nbytes in
	  let s : string = Obj.magic r in
	  let l = String.length s in
	  let n = (l + lsub - 1) / lsub in
	    bprint_fields b n (
	      fun i -> 
		let isub = i * nbytes in
		let len = min (l - isub) lsub in
		  if l <= isub + nbytes then 
		    sprintf "%S" (String.sub s isub len)
		  else
		    sprintf "%S..." (String.sub s isub len)
	    )

      | _ ->
	  ()
  in
    string_with_buffer 20 bprint

let follow_all ~src ~field ~dst =
  true

let make_context ?(max_fields=5) ?(follow=follow_all) () =
object(self)

  method graph_attrs =
    [
      "rankdir", "LR";
      "splines", "true";
      "overlap", "false";
      "sep", "0.1"
    ]

  method all_nodes_attrs =
    [
      "shape", "record";
      "penwidth", "2.0";
      "style", "rounded, filled"
    ]

  method all_edges_attrs =
    [
      "dir", "both";
      "arrowtail", "odot"
    ]

  method node_attrs ?(root=false) r =
    let attrs_for_root attrs = 
      if root then
	(* ("fontcolor", "#ff0000") :: *) ("penwidth", "8.0") :: attrs
      else
	attrs
    in
      [ "label", label_of_value self r ] |>> attrs_for_value r |>> attrs_for_root

  method edge_attrs ~src ~field ~dst =
    [ "label", string_of_int field ]

  method should_inline r = 
    match Value.tag r with
      | Value.Custom -> (
	  match Value.custom_value r with
	    | Value.Custom_nativeint _
	    | Value.Custom_int32 _
	    | Value.Custom_int64 _ -> true
	    | _                    -> false )
      | Value.Int
      | Value.Unaligned
      | Value.Out_of_heap
      | Value.Double -> true
      | _            -> false

  method should_follow_edge ~src ~field ~dst =
    follow ~src ~field ~dst

  method max_fields_for_node r =
    max_fields
end

let default_context = make_context ()

(*----------------------------------------------------------------------------*)

let dump_with_formatter ?(context=default_context) fmt o =
  let queue = Queue.create () in

  let rec value2nid = HT.create 31337
  and node_id_of_value r =
    try node_id_find r with Not_found -> (
      let id = sprintf "%s_%d" (Value.mnemonic r) (HT.length value2nid) in
	(* Make sure the node will exist. *)
	Queue.add r queue;
	HT.add value2nid r id;
	id
    )
  and node_id_find r =
    HT.find value2nid r
  in

  let node_open fmt id =
    fprintf fmt "@[<2>%s@ [" id
  and node_close fmt () =
    fprintf fmt "];@]@,"
  and link_open fmt id i fid =
    let src = id in
    let dst = fid in
      fprintf fmt "@[<2>%s ->@ %s@ [" src dst
  and link_close fmt () =
    fprintf fmt "];@]@,"
  and attr_open fmt name =
    fprintf fmt "@[<h>%s = " name
  and attr_close fmt () =
    fprintf fmt ",@]@ "
  in

  let rec node_one fmt id attrs =
    node_open fmt id;
    attr_list fmt attrs;
    node_close fmt ()
  and link_one fmt id i fid attrs =
    link_open fmt id i fid;
    attr_list fmt attrs;
    link_close fmt ()
  and attr_one fmt name value =
    attr_open fmt name;
    fprintf fmt "%S" value;
    attr_close fmt ()
  and attr_list fmt attrs =
      (* The list has to be reversed because of the way Graphviz handles
	 duplicate attributes. *)
      List.iter (fun (k,v) -> attr_one fmt k v) (List.rev attrs)
  in

  let rec dot_fields fmt id r =
    if Obj.tag r < Obj.no_scan_tag then (
      let n = Obj.size r in
	for i = 0 to n - 1 do
	  let dst = Obj.field r i and src = r in
	  let dont_inline = not (context#should_inline dst)
	  and do_follow = context#should_follow_edge ~src ~field:i ~dst
	  in
	    if dont_inline && do_follow then (
	      (* Make sure the node will exist *)
	      let edge_attrs = context#edge_attrs ~src ~field:i ~dst in
	      let fid = node_id_of_value dst in
		link_one fmt id i fid edge_attrs
	    )
	done
    )
  and dot_value ?(root=false) fmt id r =
    let node_attrs = context#node_attrs ~root r in
      node_one fmt id node_attrs;
      dot_fields fmt id r
  in

  let r = Obj.repr o in
  let root_id = node_id_of_value r in
    fprintf fmt "@[<v>@[<v 2>digraph {@,";
    node_one fmt "graph" (("root", root_id) :: context#graph_attrs);
    node_one fmt "node" context#all_nodes_attrs;
    node_one fmt "edge" context#all_edges_attrs;
    while not (Queue.is_empty queue) do
      let r = Queue.pop queue in
	dot_value fmt (node_id_of_value r) r
    done;
    fprintf fmt "@]@,}@]";
    pp_print_newline fmt ()

(*----------------------------------------------------------------------------*)
