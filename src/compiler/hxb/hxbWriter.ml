open Globals
open Ast
open Type
open HxbData
open Tanon_identification

let rec binop_index op = match op with
	| OpAdd -> 0
	| OpMult -> 1
	| OpDiv -> 2
	| OpSub -> 3
	| OpAssign -> 4
	| OpEq -> 5
	| OpNotEq -> 6
	| OpGt -> 7
	| OpGte -> 8
	| OpLt -> 9
	| OpLte -> 10
	| OpAnd -> 11
	| OpOr -> 12
	| OpXor -> 13
	| OpBoolAnd -> 14
	| OpBoolOr -> 15
	| OpShl -> 16
	| OpShr -> 17
	| OpUShr -> 18
	| OpMod -> 19
	| OpInterval -> 20
	| OpArrow -> 21
	| OpIn -> 22
	| OpNullCoal -> 23
	| OpAssignOp op -> 30 + binop_index op

let unop_index op flag = match op,flag with
	| Increment,Prefix -> 0
	| Decrement,Prefix -> 1
	| Not,Prefix -> 2
	| Neg,Prefix -> 3
	| NegBits,Prefix -> 4
	| Spread,Prefix -> 5
	| Increment,Postfix -> 6
	| Decrement,Postfix -> 7
	| Not,Postfix -> 8
	| Neg,Postfix -> 9
	| NegBits,Postfix -> 10
	| Spread,Postfix -> 11

type hxb_writer_stats = {
	type_instance_kind_writes : int array;
	texpr_writes : int array;
	type_instance_immediate : int ref;
	type_instance_cache_hits : int ref;
	type_instance_cache_misses : int ref;
	pos_writes_full : int ref;
	pos_writes_min : int ref;
	pos_writes_max : int ref;
	pos_writes_minmax : int ref;
	pos_writes_eq : int ref;
	chunk_sizes : (string,int ref * int ref) Hashtbl.t;
}

let create_hxb_writer_stats () = {
	type_instance_kind_writes = Array.make 255 0;
	texpr_writes = Array.make 255 0;
	type_instance_immediate = ref 0;
	type_instance_cache_hits = ref 0;
	type_instance_cache_misses = ref 0;
	pos_writes_full = ref 0;
	pos_writes_min = ref 0;
	pos_writes_max = ref 0;
	pos_writes_minmax = ref 0;
	pos_writes_eq = ref 0;
	chunk_sizes = Hashtbl.create 0;
}

let dump_stats name stats =
	let sort_and_filter_array a =
		let _,kind_writes = Array.fold_left (fun (index,acc) writes ->
			(index + 1,if writes = 0 then acc else (index,writes) :: acc)
		) (0,[]) a in
		let kind_writes = List.sort (fun (_,writes1) (_,writes2) -> compare writes2 writes1) kind_writes in
		List.map (fun (index,writes) -> Printf.sprintf "    %3i: %9i" index writes) kind_writes
	in
	let t_kind_writes = sort_and_filter_array stats.type_instance_kind_writes in
	print_endline (Printf.sprintf "hxb_writer stats for %s" name);
	print_endline "  type instance kind writes:";
	List.iter print_endline t_kind_writes;
	let texpr_writes = sort_and_filter_array stats.texpr_writes in
	print_endline "  texpr writes:";
	List.iter print_endline texpr_writes;

	print_endline "  type instance writes:";
	print_endline (Printf.sprintf "     immediate: %9i" !(stats.type_instance_immediate));
	print_endline (Printf.sprintf "    cache hits: %9i" !(stats.type_instance_cache_hits));
	print_endline (Printf.sprintf "    cache miss: %9i" !(stats.type_instance_cache_misses));
	print_endline "  pos writes:";
	print_endline (Printf.sprintf "      full: %9i\n       min: %9i\n       max: %9i\n    minmax: %9i\n     equal: %9i" !(stats.pos_writes_full) !(stats.pos_writes_min) !(stats.pos_writes_max) !(stats.pos_writes_minmax) !(stats.pos_writes_eq));
	(* let chunk_sizes = Hashtbl.fold (fun name (imin,imax) acc -> (name,!imin,!imax) :: acc) stats.chunk_sizes [] in
	let chunk_sizes = List.sort (fun (_,imin1,imax1) (_,imin2,imax2) -> compare imax1 imax2) chunk_sizes in
	print_endline "chunk sizes:";
	List.iter (fun (name,imin,imax) ->
		print_endline (Printf.sprintf "    %s: %i - %i" name imin imax)
	) chunk_sizes *)

module StringHashtbl = Hashtbl.Make(struct
	type t = string

	let equal =
		String.equal

	let hash s =
		(* What's the best here? *)
		Hashtbl.hash s
end)

module StringPool = struct
	type t = {
		lut : int StringHashtbl.t;
		items : string DynArray.t;
	}

	let create () = {
		lut = StringHashtbl.create 16;
		items = DynArray.create ();
	}

	let add sp s =
		let index = DynArray.length sp.items in
		StringHashtbl.add sp.lut s index;
		DynArray.add sp.items s;
		index

	let get sp s =
		StringHashtbl.find sp.lut s

	let get_or_add sp s =
		try
			get sp s
		with Not_found ->
			add sp s

	let get_sorted_items sp =
		DynArray.to_list sp.items,DynArray.length sp.items
end

class ['key,'value] pool = object(self)
	val lut = Hashtbl.create 0
	val items = DynArray.create ()

	method add (key : 'key) (value : 'value) =
		let index = DynArray.length items in
		DynArray.add items value;
		Hashtbl.add lut key index;
		index

	method extract (key : 'key) =
		DynArray.get items (self#get key)

	method has (key : 'key) =
		Hashtbl.mem lut key

	method get (key : 'key) =
		Hashtbl.find lut key

	method get_or_add (key : 'key) (value : 'value) =
		try
			self#get key
		with Not_found ->
			self#add key value

	method is_empty =
		DynArray.length items = 0

	method advance dummy =
		DynArray.add items dummy

	method to_list =
		DynArray.to_list items

	method items = items
end

class ['key,'value] identity_pool = object(self)
	val items = DynArray.create ()

	method add (key : 'key) (value : 'value) =
		let index = DynArray.length items in
		DynArray.add items (key,value);
		index

	method get (key : 'key) =
		DynArray.index_of (fun (key',_) -> key == key') items

	method get_or_add (key : 'key) (value : 'value) =
		try
			self#get key
		with Not_found ->
			self#add key value

	method to_list =
		DynArray.to_list items

	method items = items

	method length = DynArray.length items
end

class ['hkey,'key,'value] hashed_identity_pool = object(self)
	val lut = Hashtbl.create 0
	val items = DynArray.create ()

	method add (hkey : 'hkey) (key : 'key) (value : 'value) =
		let index = DynArray.length items in
		DynArray.add items (key,value);
		Hashtbl.add lut hkey (key,index);
		index

	method get (hkey : 'hkey) (key : 'key) =
		let l = Hashtbl.find_all lut hkey in
		List.assq key l

	method items = items
end

module SimnBuffer = struct
	type t = {
		buffer_size : int;
		mutable buffer : bytes;
		mutable buffers : bytes Queue.t;
		mutable offset : int;
	}

	let create buffer_size = {
		buffer = Bytes.create buffer_size;
		buffers = Queue.create ();
		offset = 0;
		buffer_size = buffer_size;
	}

	let reset sb =
		sb.buffer <- Bytes.create sb.buffer_size;
		sb.buffers <- Queue.create ();
		sb.offset <- 0

	let promote_buffer sb =
		Queue.add sb.buffer sb.buffers;
		sb.buffer <- Bytes.create sb.buffer_size;
		sb.offset <- 0

	let add_u8 sb i =
		if sb.offset = sb.buffer_size then begin
			(* Current buffer is full, promote it. *)
			promote_buffer sb;
			Bytes.unsafe_set sb.buffer 0 i;
			sb.offset <- 1;
		end else begin
			(* There's room, put it in. *)
			Bytes.unsafe_set sb.buffer sb.offset i;
			sb.offset <- sb.offset + 1
		end

	let add_bytes sb bytes =
		let rec loop offset left =
			let space = sb.buffer_size - sb.offset in
			if left > space then begin
				(* We need more than we have. Blit as much as we can, promote buffer, recurse. *)
				Bytes.unsafe_blit bytes offset sb.buffer sb.offset space;
				promote_buffer sb;
				loop (offset + space) (left - space)
			end else begin
				(* It fits, blit it. *)
				Bytes.unsafe_blit bytes offset sb.buffer sb.offset left;
				sb.offset <- sb.offset + left;
			end
		in
		loop 0 (Bytes.length bytes)

	let contents sb =
		let size = sb.offset + sb.buffer_size * Queue.length sb.buffers in
		let out = Bytes.create size in
		let offset = ref 0 in
		(* We know that all sb.buffers are of sb.buffer_size length, so blit them together. *)
		Queue.iter (fun bytes ->
			Bytes.unsafe_blit bytes 0 out !offset sb.buffer_size;
			offset := !offset + sb.buffer_size;
		) sb.buffers;
		(* Append our current buffer until sb.offset *)
		Bytes.unsafe_blit sb.buffer 0 out !offset sb.offset;
		out
end

module Chunk = struct
	type t = {
		kind : chunk_kind;
		cp : StringPool.t;
		ch : SimnBuffer.t;
	}

	let create kind cp initial_size = {
		kind;
		cp;
		ch = SimnBuffer.create initial_size;
	}

	let reset chunk =
		SimnBuffer.reset chunk.ch

	let write_u8 io v =
		SimnBuffer.add_u8 io.ch (Char.unsafe_chr v)

	let write_i32 io v =
		let base = Int32.to_int v in
		let big = Int32.to_int (Int32.shift_right_logical v 24) in
		write_u8 io base;
		write_u8 io (base lsr 8);
		write_u8 io (base lsr 16);
		write_u8 io big

	let write_i64 io v =
		write_i32 io (Int64.to_int32 v);
		write_i32 io (Int64.to_int32 (Int64.shift_right_logical v 32))

	let write_f64 io v =
		write_i64 io (Int64.bits_of_float v)

	let write_bytes io b =
		SimnBuffer.add_bytes io.ch b

	let write_ui16 io i =
		write_u8 io i;
		write_u8 io (i lsr 8)

	let get_bytes io =
		SimnBuffer.contents io.ch

	let rec write_uleb128 io v =
		let b = v land 0x7F in
		let rest = v lsr 7 in
		if rest = 0 then
			write_u8 io b
		else begin
			write_u8 io (b lor 0x80);
			write_uleb128 io rest
		end

	let rec write_leb128 io v =
		let b = v land 0x7F in
		let rest = v asr 7 in
		if (rest = 0 && (b land 0x40 = 0)) || (rest = -1 && (b land 0x40 = 0x40)) then
			write_u8 io b
		else begin
			write_u8 io (b lor 0x80);
			write_leb128 io rest
		end

	let write_bytes_length_prefixed io b =
		write_uleb128 io (Bytes.length b);
		write_bytes io b

	let write_bool io b =
		write_u8 io (if b then 1 else 0)

	let export : 'a . hxb_writer_stats -> t -> 'a IO.output -> unit = fun stats io chex ->
		let bytes = get_bytes io in
		let length = Bytes.length bytes in
		write_chunk_prefix io.kind length chex;
		(* begin try
			let (imin,imax) = Hashtbl.find stats.chunk_sizes io.name in
			if length < !imin then imin := length;
			if length > !imax then imax := length
		with Not_found ->
			Hashtbl.add stats.chunk_sizes io.name (ref length,ref length);
		end; *)
		IO.nwrite chex bytes

	let write_string chunk s =
		write_uleb128 chunk (StringPool.get_or_add chunk.cp s)

	let write_list : 'b . t -> 'b list -> ('b -> unit) -> unit = fun chunk l f ->
		write_uleb128 chunk (List.length l);
		List.iter f l

	let write_option : 'b . t -> 'b option -> ('b -> unit) -> unit = fun chunk v f -> match v with
	| None ->
		write_u8 chunk 0
	| Some v ->
		write_u8 chunk 1;
		f v

	let export_data chunk_from chunk_to =
		let bytes = get_bytes chunk_from in
		write_bytes chunk_to bytes
end

module PosWriter = struct
	type t = {
		stats : hxb_writer_stats;
		mutable p_file : string;
		mutable p_min : int;
		mutable p_max : int;
	}

	let do_write_pos (chunk : Chunk.t) (p : pos) =
		(* incr stats.pos_writes_full; *)
		Chunk.write_string chunk p.pfile;
		Chunk.write_leb128 chunk p.pmin;
		Chunk.write_leb128 chunk p.pmax

	let create stats chunk p =
		do_write_pos chunk p;
	{
		stats;
		p_file = p.pfile;
		p_min = p.pmin;
		p_max = p.pmax;
	}

	let write_pos pw (chunk : Chunk.t) (write_equal : bool) (offset : int) (p : pos) =
		if p.pfile != pw.p_file then begin
			(* File changed, write full pos *)
			Chunk.write_u8 chunk (4 + offset);
			do_write_pos chunk p;
			pw.p_file <- p.pfile;
			pw.p_min <- p.pmin;
			pw.p_max <- p.pmax;
		end else if p.pmin <> pw.p_min then begin
			if p.pmax <> pw.p_max then begin
				(* pmin and pmax changed *)
				(* incr stats.pos_writes_minmax; *)
				Chunk.write_u8 chunk (3 + offset);
				Chunk.write_leb128 chunk p.pmin;
				Chunk.write_leb128 chunk p.pmax;
				pw.p_min <- p.pmin;
				pw.p_max <- p.pmax;
			end else begin
				(* pmin changed *)
				(* incr stats.pos_writes_min; *)
				Chunk.write_u8 chunk (1 + offset);
				Chunk.write_leb128 chunk p.pmin;
				pw.p_min <- p.pmin;
			end
		end else if p.pmax <> pw.p_max then begin
			(* pmax changed *)
			(* incr stats.pos_writes_max; *)
			Chunk.write_u8 chunk (2 + offset);
			Chunk.write_leb128 chunk p.pmax;
			pw.p_max <- p.pmax;
		end else begin
			(* incr stats.pos_writes_eq; *)
			if write_equal then
				Chunk.write_u8 chunk offset;
		end
end

type field_writer_context = {
	t_pool : StringPool.t;
	pos_writer : PosWriter.t;
	mutable texpr_this : texpr option;
	vars : (int,tvar) pool;
}

let create_field_writer_context pos_writer = {
	t_pool = StringPool.create ();
	pos_writer = pos_writer;
	texpr_this = None;
	vars = new pool;
}

type hxb_writer = {
	warn : Warning.warning -> string -> Globals.pos -> unit;
	anon_id : Type.t Tanon_identification.tanon_identification;
	stats : hxb_writer_stats;
	mutable current_module : module_def;
	chunks : Chunk.t DynArray.t;
	cp : StringPool.t;
	docs : StringPool.t;
	mutable chunk : Chunk.t;

	classes : (path,tclass) pool;
	enums : (path,tenum) pool;
	typedefs : (path,tdef) pool;
	abstracts : (path,tabstract) pool;
	anons : (path,tanon) pool;
	anon_fields : (tclass_field,unit) identity_pool;
	tmonos : (tmono,unit) identity_pool;

	own_classes : (path,tclass) pool;
	own_enums : (path,tenum) pool;
	own_typedefs : (path,tdef) pool;
	own_abstracts : (path,tabstract) pool;
	type_param_lut : (path,(string,typed_type_param) pool) pool;
	class_fields : (string,tclass_field,(tclass * class_field_ref_kind * int)) hashed_identity_pool;
	enum_fields : ((path * string),(tenum * tenum_field)) pool;
	mutable type_type_parameters : (string,typed_type_param) pool;
	mutable field_type_parameters : (typed_type_param,unit) identity_pool;
	mutable local_type_parameters : (typed_type_param,unit) identity_pool;
	mutable field_stack : unit list;
	unbound_ttp : (typed_type_param,unit) identity_pool;
	t_instance_chunk : Chunk.t;
}

module HxbWriter = struct
	let in_nested_scope writer = match writer.field_stack with
		| [] -> false (* can happen for cl_init and in EXD *)
		| [_] -> false
		| _ -> true

	(* Chunks *)

	let start_chunk writer (kind : chunk_kind) =
		let initial_size = match kind with
			| EOT | EOF | EOM -> 0
			| MDF -> 16
			| MTF | CLR | END | ABD | ENR | ABR | TDR | EFR | CFR | AFD -> 64
			| AFR | CLD | TDD | EFD -> 128
			| STR | DOC -> 256
			| CFD | EXD -> 512
		in
		let new_chunk = Chunk.create kind writer.cp initial_size in
		DynArray.add writer.chunks new_chunk;
		writer.chunk <- new_chunk

	let start_temporary_chunk : 'a . hxb_writer -> int -> (Chunk.t -> 'a) -> 'a = fun writer initial_size ->
		let new_chunk = Chunk.create EOM (* TODO: something else? *) writer.cp initial_size in
		let old_chunk = writer.chunk in
		writer.chunk <- new_chunk;
		(fun f ->
			writer.chunk <- old_chunk;
			f new_chunk
		)

	let write_inlined_list : 'a . hxb_writer -> int -> int -> (int -> unit) -> (unit -> unit) -> ('a -> unit) -> 'a list -> unit
		= fun writer offset max f_byte f_first f_elt l ->
		let length = List.length l in
		if length > max then begin
			f_byte (offset + 9);
			f_first ();
			Chunk.write_list writer.chunk l f_elt
		end else begin
			f_byte (offset + length);
			f_first();
			List.iter (fun elt ->
				f_elt elt
			) l
		end

	(* Basic compounds *)

	let write_path writer (path : path) =
		Chunk.write_list writer.chunk (fst path) (Chunk.write_string writer.chunk);
		Chunk.write_string writer.chunk (snd path)

	let write_full_path writer (pack : string list) (mname : string) (tname : string) =
		Chunk.write_list writer.chunk pack (Chunk.write_string writer.chunk);
		Chunk.write_string writer.chunk mname;
		Chunk.write_string writer.chunk tname

	let write_documentation writer (doc : doc_block) =
		Chunk.write_option writer.chunk doc.doc_own (fun s ->
			Chunk.write_uleb128 writer.chunk (StringPool.get_or_add writer.docs s)
		);
		Chunk.write_list writer.chunk doc.doc_inherited (fun s ->
			Chunk.write_uleb128 writer.chunk (StringPool.get_or_add writer.docs s)
		)

	let write_pos writer (p : pos) =
		Chunk.write_string writer.chunk p.pfile;
		Chunk.write_leb128 writer.chunk p.pmin;
		Chunk.write_leb128 writer.chunk p.pmax

	let rec write_metadata_entry writer ((meta,el,p) : metadata_entry) =
		Chunk.write_string writer.chunk (Meta.to_string meta);
		write_pos writer p;
		Chunk.write_list writer.chunk el (write_expr writer)

	and write_metadata writer ml =
		Chunk.write_list writer.chunk ml (write_metadata_entry writer)

	(* expr *)

	and write_object_field_key writer (n,p,qs) =
		Chunk.write_string writer.chunk n;
		write_pos writer p;
		begin match qs with
			| NoQuotes -> Chunk.write_u8 writer.chunk 0
			| DoubleQuotes -> Chunk.write_u8 writer.chunk 1
		end

	and write_type_path writer tp =
		Chunk.write_list writer.chunk tp.tpackage (Chunk.write_string writer.chunk);
		Chunk.write_string writer.chunk tp.tname;
		Chunk.write_list writer.chunk tp.tparams (write_type_param_or_const writer);
		Chunk.write_option writer.chunk tp.tsub (Chunk.write_string writer.chunk)

	and write_placed_type_path writer ptp =
		write_type_path writer ptp.path;
		write_pos writer ptp.pos_full;
		write_pos writer ptp.pos_path

	and write_type_param_or_const writer = function
		| TPType th ->
			Chunk.write_u8 writer.chunk 0;
			write_type_hint writer th
		| TPExpr e ->
			Chunk.write_u8 writer.chunk 1;
			write_expr writer e

	and write_complex_type writer = function
		| CTPath tp ->
			Chunk.write_u8 writer.chunk 0;
			write_placed_type_path writer tp
		| CTFunction(thl,th) ->
			Chunk.write_u8 writer.chunk 1;
			Chunk.write_list writer.chunk thl (write_type_hint writer);
			write_type_hint writer th
		| CTAnonymous cffl ->
			Chunk.write_u8 writer.chunk 2;
			Chunk.write_list writer.chunk cffl (write_cfield writer);
		| CTParent th ->
			Chunk.write_u8 writer.chunk 3;
			write_type_hint writer th
		| CTExtend(ptp,cffl) ->
			Chunk.write_u8 writer.chunk 4;
			Chunk.write_list writer.chunk ptp (write_placed_type_path writer);
			Chunk.write_list writer.chunk cffl (write_cfield writer);
		| CTOptional th ->
			Chunk.write_u8 writer.chunk 5;
			write_type_hint writer th
		| CTNamed(pn,th) ->
			Chunk.write_u8 writer.chunk 6;
			write_placed_name writer pn;
			write_type_hint writer th
		| CTIntersection(thl) ->
			Chunk.write_u8 writer.chunk 7;
			Chunk.write_list writer.chunk thl (write_type_hint writer)

	and write_type_hint writer (ct,p) =
		write_complex_type writer ct;
		write_pos writer p

	and write_type_param writer tp =
		write_placed_name writer tp.tp_name;
		Chunk.write_list writer.chunk tp.tp_params (write_type_param writer);
		Chunk.write_option writer.chunk tp.tp_constraints (write_type_hint writer);
		Chunk.write_option writer.chunk tp.tp_default (write_type_hint writer);
		Chunk.write_list writer.chunk tp.tp_meta (write_metadata_entry writer)

	and write_func_arg writer (pn,b,meta,tho,eo) =
		write_placed_name writer pn;
		Chunk.write_bool writer.chunk b;
		write_metadata writer meta;
		Chunk.write_option writer.chunk tho (write_type_hint writer);
		Chunk.write_option writer.chunk eo (write_expr writer);

	and write_func writer f =
		Chunk.write_list writer.chunk f.f_params (write_type_param writer);
		Chunk.write_list writer.chunk f.f_args (write_func_arg writer);
		Chunk.write_option writer.chunk f.f_type (write_type_hint writer);
		Chunk.write_option writer.chunk f.f_expr (write_expr writer)

	and write_placed_name writer (s,p) =
		Chunk.write_string writer.chunk s;
		write_pos writer p

	and write_access writer ac =
		let i = match ac with
		| APublic -> 0
		| APrivate -> 1
		| AStatic -> 2
		| AOverride -> 3
		| ADynamic -> 4
		| AInline -> 5
		| AMacro -> 6
		| AFinal -> 7
		| AExtern -> 8
		| AAbstract -> 9
		| AOverload -> 10
		| AEnum -> 11
		in
		Chunk.write_u8 writer.chunk i

	and write_placed_access writer (ac,p) =
		write_access writer ac;
		write_pos writer p

	and write_cfield_kind writer = function
		| FVar(tho,eo) ->
			Chunk.write_u8 writer.chunk 0;
			Chunk.write_option writer.chunk tho (write_type_hint writer);
			Chunk.write_option writer.chunk eo (write_expr writer);
		| FFun f ->
			Chunk.write_u8 writer.chunk 1;
			write_func writer f;
		| FProp(pn1,pn2,tho,eo) ->
			Chunk.write_u8 writer.chunk 2;
			write_placed_name writer pn1;
			write_placed_name writer pn2;
			Chunk.write_option writer.chunk tho (write_type_hint writer);
			Chunk.write_option writer.chunk eo (write_expr writer)

	and write_cfield writer cff =
		write_placed_name writer cff.cff_name;
		Chunk.write_option writer.chunk cff.cff_doc (write_documentation writer);
		write_pos writer cff.cff_pos;
		write_metadata writer cff.cff_meta;
		Chunk.write_list writer.chunk cff.cff_access (write_placed_access writer);
		write_cfield_kind writer cff.cff_kind

	and write_expr writer (e,p) =
		write_pos writer p;
		match e with
		| EConst (Int (s, suffix)) ->
			Chunk.write_u8 writer.chunk 0;
			Chunk.write_string writer.chunk s;
			Chunk.write_option writer.chunk suffix (Chunk.write_string writer.chunk);
		| EConst (Float (s, suffix)) ->
			Chunk.write_u8 writer.chunk 1;
			Chunk.write_string writer.chunk s;
			Chunk.write_option writer.chunk suffix (Chunk.write_string writer.chunk);
		| EConst (String (s,qs)) ->
			Chunk.write_u8 writer.chunk 2;
			Chunk.write_string writer.chunk s;
			begin match qs with
			| SDoubleQuotes -> Chunk.write_u8 writer.chunk 0;
			| SSingleQuotes -> Chunk.write_u8 writer.chunk 1;
			end
		| EConst (Ident s) ->
			Chunk.write_u8 writer.chunk 3;
			Chunk.write_string writer.chunk s;
		| EConst (Regexp(s1,s2)) ->
			Chunk.write_u8 writer.chunk 4;
			Chunk.write_string writer.chunk s1;
			Chunk.write_string writer.chunk s2;
		| EArray(e1,e2) ->
			Chunk.write_u8 writer.chunk 5;
			write_expr writer e1;
			write_expr writer e2;
		| EBinop(op,e1,e2) ->
			Chunk.write_u8 writer.chunk 6;
			Chunk.write_u8 writer.chunk (binop_index op);
			write_expr writer e1;
			write_expr writer e2;
		| EField(e1,s,kind) ->
			Chunk.write_u8 writer.chunk 7;
			write_expr writer e1;
			Chunk.write_string writer.chunk s;
			begin match kind with
			| EFNormal -> Chunk.write_u8 writer.chunk 0;
			| EFSafe -> Chunk.write_u8 writer.chunk 1;
			end
		| EParenthesis e1 ->
			Chunk.write_u8 writer.chunk 8;
			write_expr writer e1;
		| EObjectDecl fl ->
			Chunk.write_u8 writer.chunk 9;
			let write_field (k,e1) =
				write_object_field_key writer k;
				write_expr writer e1
			in
			Chunk.write_list writer.chunk fl write_field;
		| EArrayDecl el ->
			Chunk.write_u8 writer.chunk 10;
			Chunk.write_list writer.chunk el (write_expr writer);
		| ECall(e1,el) ->
			Chunk.write_u8 writer.chunk 11;
			write_expr writer e1;
			Chunk.write_list writer.chunk el (write_expr writer)
		| ENew(ptp,el) ->
			Chunk.write_u8 writer.chunk 12;
			write_placed_type_path writer ptp;
			Chunk.write_list writer.chunk el (write_expr writer);
		| EUnop(op,flag,e1) ->
			Chunk.write_u8 writer.chunk 13;
			Chunk.write_u8 writer.chunk (unop_index op flag);
			write_expr writer e1;
		| EVars vl ->
			Chunk.write_u8 writer.chunk 14;
			let write_var v =
				write_placed_name writer v.ev_name;
				Chunk.write_bool writer.chunk v.ev_final;
				Chunk.write_bool writer.chunk v.ev_static;
				Chunk.write_option writer.chunk v.ev_type (write_type_hint writer);
				Chunk.write_option writer.chunk v.ev_expr (write_expr writer);
				write_metadata writer v.ev_meta;
			in
			Chunk.write_list writer.chunk vl write_var
		| EFunction(fk,f) ->
			Chunk.write_u8 writer.chunk 15;
			begin match fk with
			| FKAnonymous -> Chunk.write_u8 writer.chunk 0;
			| FKNamed (pn,inline) ->
				Chunk.write_u8 writer.chunk 1;
				write_placed_name writer pn;
				Chunk.write_bool writer.chunk inline;
			| FKArrow -> Chunk.write_u8 writer.chunk 2;
			end;
			write_func writer f;
		| EBlock el ->
			Chunk.write_u8 writer.chunk 16;
			Chunk.write_list writer.chunk el (write_expr writer)
		| EFor(e1,e2) ->
			Chunk.write_u8 writer.chunk 17;
			write_expr writer e1;
			write_expr writer e2;
		| EIf(e1,e2,None) ->
			Chunk.write_u8 writer.chunk 18;
			write_expr writer e1;
			write_expr writer e2;
		| EIf(e1,e2,Some e3) ->
			Chunk.write_u8 writer.chunk 19;
			write_expr writer e1;
			write_expr writer e2;
			write_expr writer e3;
		| EWhile(e1,e2,NormalWhile) ->
			Chunk.write_u8 writer.chunk 20;
			write_expr writer e1;
			write_expr writer e2;
		| EWhile(e1,e2,DoWhile) ->
			Chunk.write_u8 writer.chunk 21;
			write_expr writer e1;
			write_expr writer e2;
		| ESwitch(e1,cases,def) ->
			Chunk.write_u8 writer.chunk 22;
			write_expr writer e1;
			let write_case (el,eg,eo,p) =
				Chunk.write_list writer.chunk el (write_expr writer);
				Chunk.write_option writer.chunk eg (write_expr writer);
				Chunk.write_option writer.chunk eo (write_expr writer);
				write_pos writer p;
			in
			Chunk.write_list writer.chunk cases write_case;
			let write_default (eo,p) =
				Chunk.write_option writer.chunk eo (write_expr writer);
				write_pos writer p
			in
			Chunk.write_option writer.chunk def write_default;
		| ETry(e1,catches) ->
			Chunk.write_u8 writer.chunk 23;
			write_expr writer e1;
			let write_catch (pn,th,e,p) =
				write_placed_name writer pn;
				Chunk.write_option writer.chunk th (write_type_hint writer);
				write_expr writer e;
				write_pos writer p;
			in
			Chunk.write_list writer.chunk catches write_catch;
		| EReturn None ->
			Chunk.write_u8 writer.chunk 24;
		| EReturn (Some e1) ->
			Chunk.write_u8 writer.chunk 25;
			write_expr writer e1;
		| EBreak ->
			Chunk.write_u8 writer.chunk 26;
		| EContinue ->
			Chunk.write_u8 writer.chunk 27;
		| EUntyped e1 ->
			Chunk.write_u8 writer.chunk 28;
			write_expr writer e1;
		| EThrow e1 ->
			Chunk.write_u8 writer.chunk 29;
			write_expr writer e1;
		| ECast(e1,None) ->
			Chunk.write_u8 writer.chunk 30;
			write_expr writer e1;
		| ECast(e1,Some th) ->
			Chunk.write_u8 writer.chunk 31;
			write_expr writer e1;
			write_type_hint writer th;
		| EIs(e1,th) ->
			Chunk.write_u8 writer.chunk 32;
			write_expr writer e1;
			write_type_hint writer th;
		| EDisplay(e1,dk) ->
			Chunk.write_u8 writer.chunk 33;
			write_expr writer e1;
			begin match dk with
			| DKCall -> Chunk.write_u8 writer.chunk 0;
			| DKDot -> Chunk.write_u8 writer.chunk 1;
			| DKStructure -> Chunk.write_u8 writer.chunk 2;
			| DKMarked -> Chunk.write_u8 writer.chunk 3;
			| DKPattern b ->
				Chunk.write_u8 writer.chunk 4;
				Chunk.write_bool writer.chunk b;
			end
		| ETernary(e1,e2,e3) ->
			Chunk.write_u8 writer.chunk 34;
			write_expr writer e1;
			write_expr writer e2;
			write_expr writer e3;
		| ECheckType(e1,th) ->
			Chunk.write_u8 writer.chunk 35;
			write_expr writer e1;
			write_type_hint writer th;
		| EMeta(m,e1) ->
			Chunk.write_u8 writer.chunk 36;
			write_metadata_entry writer m;
			write_expr writer e1

	(* References *)

	let write_class_ref writer (c : tclass) =
		let i = writer.classes#get_or_add c.cl_path c in
		Chunk.write_uleb128 writer.chunk i

	let write_enum_ref writer (en : tenum) =
		let i = writer.enums#get_or_add en.e_path en in
		Chunk.write_uleb128 writer.chunk i

	let write_typedef_ref writer (td : tdef) =
		let i = writer.typedefs#get_or_add td.t_path td in
		Chunk.write_uleb128 writer.chunk i

	let write_abstract_ref writer (a : tabstract) =
		let i = writer.abstracts#get_or_add a.a_path a in
		Chunk.write_uleb128 writer.chunk i

	let write_tmono_ref writer (mono : tmono) =
		let index = try writer.tmonos#get mono with Not_found -> writer.tmonos#add mono () in
		Chunk.write_uleb128 writer.chunk index

	let write_field_ref writer (c : tclass) (kind : class_field_ref_kind)  (cf : tclass_field) =
		let index = try
			writer.class_fields#get cf.cf_name cf
		with Not_found ->
			let find_overload c cf_base =
				let rec loop depth cfl = match cfl with
					| cf' :: cfl ->
						if cf' == cf then
							Some(c,depth)
						else
							loop (depth + 1) cfl
					| [] ->
						None
				in
				let cfl = cf_base :: cf_base.cf_overloads in
				loop 0 cfl
			in
			let find_overload c =
				try
					find_overload c (find_field c cf.cf_name kind)
				with Not_found ->
					None
			in
			let r = match kind with
				| CfrStatic | CfrConstructor ->
					find_overload c;
				| CfrMember ->
					(* For member overloads we need to find the correct class, which is a mess. *)
					let rec loop c = match find_overload c with
						| Some _ as r ->
							r
						| None ->
							if has_class_flag c CInterface then
								let rec loopi l = match l with
									| [] ->
										None
									| (c,_) :: l ->
										match loop c with
										| Some _ as r ->
											r
										| None ->
											loopi l
								in
								loopi c.cl_implements
							else match c.cl_super with
								| Some(c,_) ->
									loop c
								| None ->
									None
					in
					loop c;
			in
			let c,depth = match r with
				| None ->
					print_endline (Printf.sprintf "Could not resolve %s overload for %s on %s" (s_class_field_ref_kind kind) cf.cf_name (s_type_path c.cl_path));
					c,0
				| Some(c,depth) ->
					c,depth
			in
			writer.class_fields#add cf.cf_name cf (c,kind,depth)
		in
		Chunk.write_uleb128 writer.chunk index

	let write_enum_field_ref writer (en : tenum) (ef : tenum_field) =
		let key = (en.e_path,ef.ef_name) in
		try
			Chunk.write_uleb128 writer.chunk (writer.enum_fields#get key)
		with Not_found ->
			ignore(writer.enums#get_or_add en.e_path en);
			Chunk.write_uleb128 writer.chunk (writer.enum_fields#add key (en,ef))

	let write_var_kind writer vk =
		let b = match vk with
			| VUser TVOLocalVariable -> 0
			| VUser TVOArgument -> 1
			| VUser TVOForVariable -> 2
			| VUser TVOPatternVariable -> 3
			| VUser TVOCatchVariable -> 4
			| VUser TVOLocalFunction -> 5
			| VGenerated -> 6
			| VInlined -> 7
			| VInlinedConstructorVariable -> 8
			| VExtractorVariable -> 9
			| VAbstractThis -> 10
		in
		Chunk.write_u8 writer.chunk b

	let write_var writer fctx v =
		Chunk.write_uleb128 writer.chunk v.v_id;
		Chunk.write_string writer.chunk v.v_name;
		write_var_kind writer v.v_kind;
		Chunk.write_uleb128 writer.chunk v.v_flags;
		write_metadata writer v.v_meta;
		write_pos writer v.v_pos

	let rec write_anon writer (an : tanon) (ttp : type_params) =
		let write_fields () =
			Chunk.write_list writer.chunk (PMap.foldi (fun s f acc -> (s,f) :: acc) an.a_fields []) (fun (_,cf) ->
				write_anon_field_ref writer cf
			)
		in
		begin match !(an.a_status) with
		| Closed ->
			Chunk.write_u8 writer.chunk 0;
			write_fields ()
		| Const ->
			Chunk.write_u8 writer.chunk 1;
			write_fields ()
		| Extend tl ->
			Chunk.write_u8 writer.chunk 2;
			write_types writer tl;
			write_fields ()
		| ClassStatics _ ->
			assert false
		| EnumStatics _ ->
			assert false
		| AbstractStatics _ ->
			assert false
		end

	and write_anon_ref writer (an : tanon) (ttp : type_params) =
		let pfm = Option.get (writer.anon_id#identify_anon ~strict:true an) in
		try
			let index = writer.anons#get pfm.pfm_path in
			Chunk.write_u8 writer.chunk 0;
			Chunk.write_uleb128 writer.chunk index
		with Not_found ->
			let index = writer.anons#add pfm.pfm_path an in
			Chunk.write_u8 writer.chunk 1;
			Chunk.write_uleb128 writer.chunk index;
			write_anon writer an ttp

	and write_anon_field_ref writer cf =
		try
			let index = writer.anon_fields#get cf in
			Chunk.write_u8 writer.chunk 0;
			Chunk.write_uleb128 writer.chunk index
		with Not_found ->
			let index = writer.anon_fields#add cf () in
			Chunk.write_u8 writer.chunk 1;
			Chunk.write_uleb128 writer.chunk index;
			ignore(write_class_field_and_overloads_data writer true cf)

	(* Type instances *)

	and write_type_parameter_ref writer (ttp : typed_type_param) =
		begin try
			begin match ttp.ttp_host with
			| TPHType ->
				let i = writer.type_type_parameters#get ttp.ttp_name in
				Chunk.write_u8 writer.chunk 1;
				Chunk.write_uleb128 writer.chunk i
			| TPHMethod | TPHEnumConstructor | TPHAnonField | TPHConstructor ->
				let i = writer.field_type_parameters#get ttp in
				Chunk.write_u8 writer.chunk 2;
				Chunk.write_uleb128 writer.chunk i;
			| TPHLocal ->
				let index = writer.local_type_parameters#get ttp in
				Chunk.write_u8 writer.chunk 3;
				Chunk.write_uleb128 writer.chunk index;
		end with Not_found ->
			(try ignore(writer.unbound_ttp#get ttp) with Not_found -> begin
				ignore(writer.unbound_ttp#add ttp ());
				let p = { null_pos with pfile = (Path.UniqueKey.lazy_path writer.current_module.m_extra.m_file) } in
				let msg = Printf.sprintf "Unbound type parameter %s" (s_type_path ttp.ttp_class.cl_path) in
				writer.warn WUnboundTypeParameter msg p
			end);
			Chunk.write_u8 writer.chunk 4; (* TDynamic None *)
		end

	(*
		simple references:
				0 - mono
				1 -> type ttp
				2 -> field ttp
				3 -> local ttp
				4 -> Dynamic

		special references:
			10 - class statics
			11 - enum statics
			12 - abstract statics
			13 - KExpr

		void functions:
			20: () -> Void
			21: (A) -> Void
			22: (A, B) -> Void
			23: (A, B, C) -> Void
			24: (A, B, C) -> Void
			29: (?) -> Void

		non-void functions:
			30: () -> T
			31: (A) -> T
			32: (A, B) -> T
			33: (A, B, C) -> T
			34: (A, B, C, D) -> T
			39: (?) -> T

		class:
			40: C
			41: C<A>
			42: C<A, B>
			49: C<?>

		enum:
			50: E
			51: E<A>
			52: E<A, B>
			59: E<?>

		typedef:
			60: T
			61: T<A>
			62: T<A, B>
			69: T<?>

		abstract:
			70: A
			71: A<A>
			72: A<A, B>
			79: A<?>

		anons:
			80: {}
			81: any anon
			89: Dynamic<T>

		concrete types:
			100: Void
			101: Int
			102: Float
			103: Bool
			104: String
	*)
	and write_type_instance writer t =
		let write_function_arg (n,o,t) =
			Chunk.write_string writer.chunk n;
			Chunk.write_bool writer.chunk o;
			write_type_instance writer t;
		in
		let write_inlined_list offset max f_first f_elt l =
			write_inlined_list writer offset max (Chunk.write_u8 writer.chunk) f_first f_elt l
		in
		match t with
			| TAbstract ({a_path = ([],"Void")},[]) ->
				Chunk.write_u8 writer.chunk 100;
			| TAbstract ({a_path = ([],"Int")},[]) ->
				Chunk.write_u8 writer.chunk 101;
			| TAbstract ({a_path = ([],"Float")},[]) ->
				Chunk.write_u8 writer.chunk 102;
			| TAbstract ({a_path = ([],"Bool")},[]) ->
				Chunk.write_u8 writer.chunk 103;
			| TInst ({cl_path = ([],"String")},[]) ->
				Chunk.write_u8 writer.chunk 104;
			| TMono r ->
				Monomorph.close r;
				begin match r.tm_type with
				| None ->
					Chunk.write_u8 writer.chunk 0;
					write_tmono_ref writer r;
					| Some t ->
					(* Don't write bound monomorphs, write underlying type directly *)
					write_type_instance writer t
				end
			| TLazy f ->
				write_type_instance writer (lazy_type f)
			| TInst({cl_kind = KTypeParameter ttp},[]) ->
				write_type_parameter_ref writer ttp;
			| TInst({cl_kind = KExpr e},[]) ->
				Chunk.write_u8 writer.chunk 13;
				write_expr writer e;
			| TInst(c,[]) ->
				Chunk.write_u8 writer.chunk 40;
				write_class_ref writer c;
			| TEnum(en,[]) ->
				Chunk.write_u8 writer.chunk 50;
				write_enum_ref writer en;
			| TType(td,[]) ->
				let default () =
					Chunk.write_u8 writer.chunk 60;
					write_typedef_ref writer td;
				in
				begin match td.t_type with
				| TAnon an ->
					begin match !(an.a_status) with
						| ClassStatics c ->
							Chunk.write_u8 writer.chunk 10;
							write_class_ref writer c
						| EnumStatics en ->
							Chunk.write_u8 writer.chunk 11;
							write_enum_ref writer en;
						| AbstractStatics a ->
							Chunk.write_u8 writer.chunk 12;
							write_abstract_ref writer a
						| _ ->
							default()
					end
				| _ ->
					default()
				end;
			| TAbstract(a,[]) ->
				Chunk.write_u8 writer.chunk 70;
				write_abstract_ref writer a;
			| TDynamic None ->
				Chunk.write_u8 writer.chunk 4;
			| TFun([],t) when ExtType.is_void (follow_lazy_and_mono t) ->
				Chunk.write_u8 writer.chunk 20;
			| TFun(args,t) when ExtType.is_void (follow_lazy_and_mono t) ->
				write_inlined_list 20 4 (fun () -> ()) write_function_arg args;
			| TFun(args,t) ->
				write_inlined_list 30 4 (fun () -> ()) write_function_arg args;
				write_type_instance writer t;
			| TInst(c,tl) ->
				write_inlined_list 40 2 (fun () -> write_class_ref writer c) (write_type_instance writer) tl;
			| TEnum(en,tl) ->
				write_inlined_list 50 2 (fun () -> write_enum_ref writer en) (write_type_instance writer) tl;
			| TType(td,tl) ->
				write_inlined_list 60 2 (fun () -> write_typedef_ref writer td) (write_type_instance writer) tl;
			| TAbstract(a,tl) ->
				write_inlined_list 70 2 (fun () -> write_abstract_ref writer a) (write_type_instance writer) tl;
			| TAnon an when PMap.is_empty an.a_fields ->
				Chunk.write_u8 writer.chunk 80;
			| TAnon an ->
				Chunk.write_u8 writer.chunk 81;
				write_anon_ref writer an []
			| TDynamic (Some t) ->
				Chunk.write_u8 writer.chunk 89;
				write_type_instance writer t

	and write_types writer tl =
		Chunk.write_list writer.chunk tl (write_type_instance writer)

	(* texpr *)

	and write_texpr_type_instance writer (fctx : field_writer_context) (t: Type.t) =
		let old_chunk = writer.chunk in
		writer.chunk <- writer.t_instance_chunk;
		Chunk.reset writer.chunk;
		write_type_instance writer t;
		let t_bytes = Chunk.get_bytes writer.chunk in
		writer.chunk <- old_chunk;
		let index = StringPool.get_or_add fctx.t_pool (Bytes.unsafe_to_string t_bytes) in
		Chunk.write_uleb128 writer.chunk index

	and write_texpr writer (fctx : field_writer_context) (e : texpr) =
		let declare_var v =
			Chunk.write_uleb128 writer.chunk (fctx.vars#add v.v_id v);
			Chunk.write_option writer.chunk v.v_extra (fun ve ->
				Chunk.write_list writer.chunk ve.v_params (fun ttp ->
					let index = writer.local_type_parameters#add ttp () in
					Chunk.write_uleb128 writer.chunk index
				);
				Chunk.write_option writer.chunk ve.v_expr (write_texpr writer fctx);
			);
			write_type_instance writer v.v_type;
		in
		let rec loop e =

			write_texpr_type_instance writer fctx e.etype;
			PosWriter.write_pos fctx.pos_writer writer.chunk true 0 e.epos;

			match e.eexpr with
			(* values 0-19 *)
			| TConst ct ->
				begin match ct with
				| TNull ->
					Chunk.write_u8 writer.chunk 0;
				| TThis ->
					fctx.texpr_this <- Some e;
					Chunk.write_u8 writer.chunk 1;
				| TSuper ->
					Chunk.write_u8 writer.chunk 2;
				| TBool false ->
					Chunk.write_u8 writer.chunk 3;
				| TBool true ->
					Chunk.write_u8 writer.chunk 4;
				| TInt i32 ->
					Chunk.write_u8 writer.chunk 5;
					Chunk.write_i32 writer.chunk i32;
				| TFloat f ->
					Chunk.write_u8 writer.chunk 6;
					Chunk.write_string writer.chunk f;
				| TString s ->
					Chunk.write_u8 writer.chunk 7;
					Chunk.write_string writer.chunk s
				end
			(* vars 20-29 *)
			| TLocal v ->
				Chunk.write_u8 writer.chunk 20;
				Chunk.write_uleb128 writer.chunk (fctx.vars#get v.v_id)
			| TVar(v,None) ->
				Chunk.write_u8 writer.chunk 21;
				declare_var v;
			| TVar(v,Some e1) ->
				Chunk.write_u8 writer.chunk 22;
				declare_var v;
				loop e1;
			(* blocks 30-49 *)
			| TBlock [] ->
				Chunk.write_u8 writer.chunk 30;
			| TBlock el ->
				let restore = start_temporary_chunk writer 256 in
				let i = ref 0 in
				List.iter (fun e ->
					incr i;
					loop e;
				) el;
				let bytes = restore (fun new_chunk -> Chunk.get_bytes new_chunk) in
				let l = !i in
				begin match l with
				| 1 -> Chunk.write_u8 writer.chunk 31;
				| 2 -> Chunk.write_u8 writer.chunk 32;
				| 3 -> Chunk.write_u8 writer.chunk 33;
				| 4 -> Chunk.write_u8 writer.chunk 34;
				| 5 -> Chunk.write_u8 writer.chunk 35;
				| _ ->
					if l <= 0xFF then begin
						Chunk.write_u8 writer.chunk 36;
						Chunk.write_u8 writer.chunk l;
					end else begin
						Chunk.write_u8 writer.chunk 39;
						Chunk.write_uleb128 writer.chunk l;
					end;
				end;
				Chunk.write_bytes writer.chunk bytes;
			(* function 50-59 *)
			| TFunction tf ->
				Chunk.write_u8 writer.chunk 50;
				Chunk.write_list writer.chunk tf.tf_args (fun (v,eo) ->
					declare_var v;
					Chunk.write_option writer.chunk eo loop;
				);
				write_type_instance writer tf.tf_type;
				loop tf.tf_expr;
			(* texpr compounds 60-79 *)
			| TArray(e1,e2) ->
				Chunk.write_u8 writer.chunk 60;
				loop e1;
				loop e2;
			| TParenthesis e1 ->
				Chunk.write_u8 writer.chunk 61;
				loop e1;
			| TArrayDecl el ->
				Chunk.write_u8 writer.chunk 62;
				loop_el el;
			| TObjectDecl fl ->
				Chunk.write_u8 writer.chunk 63;
				Chunk.write_list writer.chunk fl (fun ((name,p,qs),e) ->
					Chunk.write_string writer.chunk name;
					write_pos writer p;
					begin match qs with
					| NoQuotes -> Chunk.write_u8 writer.chunk 0;
					| DoubleQuotes -> Chunk.write_u8 writer.chunk 1;
					end;
					loop e
				);
			| TCall(e1,el) ->
				write_inlined_list writer 70 4 (Chunk.write_u8 writer.chunk) (fun () -> loop e1) loop el
			| TMeta(m,e1) ->
				Chunk.write_u8 writer.chunk 65;
				write_metadata_entry writer m;
				loop e1;
			(* branching 80-89 *)
			| TIf(e1,e2,None) ->
				Chunk.write_u8 writer.chunk 80;
				loop e1;
				loop e2;
			| TIf(e1,e2,Some e3) ->
				Chunk.write_u8 writer.chunk 81;
				loop e1;
				loop e2;
				loop e3;
			| TSwitch s ->
				Chunk.write_u8 writer.chunk 82;
				loop s.switch_subject;
				Chunk.write_list writer.chunk s.switch_cases (fun c ->
					loop_el c.case_patterns;
					loop c.case_expr;
				);
				Chunk.write_option writer.chunk s.switch_default loop;
			| TTry(e1,catches) ->
				Chunk.write_u8 writer.chunk 83;
				loop e1;
				Chunk.write_list writer.chunk catches  (fun (v,e) ->
					declare_var v;
					loop e
				);
			| TWhile(e1,e2,flag) ->
				Chunk.write_u8 writer.chunk (if flag = NormalWhile then 84 else 85);
				loop e1;
				loop e2;
			| TFor(v,e1,e2) ->
				Chunk.write_u8 writer.chunk 86;
				declare_var v;
				loop e1;
				loop e2;
			(* control flow 90-99 *)
			| TReturn None ->
				Chunk.write_u8 writer.chunk 90;
			| TReturn (Some e1) ->
				Chunk.write_u8 writer.chunk 91;
				loop e1;
			| TContinue ->
				Chunk.write_u8 writer.chunk 92;
			| TBreak ->
				Chunk.write_u8 writer.chunk 93;
			| TThrow e1 ->
				Chunk.write_u8 writer.chunk 94;
				loop e1;
			(* access 100-119 *)
			| TEnumIndex e1 ->
				Chunk.write_u8 writer.chunk 100;
				loop e1;
			| TEnumParameter(e1,ef,i) ->
				Chunk.write_u8 writer.chunk 101;
				loop e1;
				let en = match follow ef.ef_type with
					| TFun(_,tr) ->
						begin match follow tr with
							| TEnum(en,_) -> en
							| _ -> die "" __LOC__
						end
					| _ ->
						die "" __LOC__
				in
				write_enum_field_ref writer en ef;
				Chunk.write_uleb128 writer.chunk i;
			| TField({eexpr = TConst TThis; epos = p1},FInstance(c,tl,cf)) when fctx.texpr_this <> None ->
				Chunk.write_u8 writer.chunk 111;
				PosWriter.write_pos fctx.pos_writer writer.chunk true 0 p1;
				write_class_ref writer c;
				write_types writer tl;
				write_field_ref writer c CfrMember cf;
			| TField(e1,FInstance(c,tl,cf)) ->
				Chunk.write_u8 writer.chunk 102;
				loop e1;
				write_class_ref writer c;
				write_types writer tl;
				write_field_ref writer c CfrMember cf;
			| TField({eexpr = TTypeExpr (TClassDecl c'); epos = p1},FStatic(c,cf)) when c == c' ->
				Chunk.write_u8 writer.chunk 110;
				PosWriter.write_pos fctx.pos_writer writer.chunk true 0 p1;
				write_class_ref writer c;
				write_field_ref writer c CfrStatic cf;
			| TField(e1,FStatic(c,cf)) ->
				Chunk.write_u8 writer.chunk 103;
				loop e1;
				write_class_ref writer c;
				write_field_ref writer c CfrStatic cf;
			| TField(e1,FAnon cf) ->
				Chunk.write_u8 writer.chunk 104;
				loop e1;
				write_anon_field_ref writer cf
			| TField(e1,FClosure(Some(c,tl),cf)) ->
				Chunk.write_u8 writer.chunk 105;
				loop e1;
				write_class_ref writer c;
				write_types writer tl;
				write_field_ref writer c CfrMember cf
			| TField(e1,FClosure(None,cf)) ->
				Chunk.write_u8 writer.chunk 106;
				loop e1;
				write_anon_field_ref writer cf
			| TField(e1,FEnum(en,ef)) ->
				Chunk.write_u8 writer.chunk 107;
				loop e1;
				write_enum_ref writer en;
				write_enum_field_ref writer en ef;
			| TField(e1,FDynamic s) ->
				Chunk.write_u8 writer.chunk 108;
				loop e1;
				Chunk.write_string writer.chunk s;
			(* module types 120-139 *)
			| TTypeExpr (TClassDecl ({cl_kind = KTypeParameter ttp})) ->
				Chunk.write_u8 writer.chunk 128;
				write_type_parameter_ref writer ttp
			| TTypeExpr (TClassDecl c) ->
				Chunk.write_u8 writer.chunk 120;
				write_class_ref writer c;
			| TTypeExpr (TEnumDecl en) ->
				Chunk.write_u8 writer.chunk 121;
				write_enum_ref writer en;
			| TTypeExpr (TAbstractDecl a) ->
				Chunk.write_u8 writer.chunk 122;
				write_abstract_ref writer a
			| TTypeExpr (TTypeDecl td) ->
				Chunk.write_u8 writer.chunk 123;
				write_typedef_ref writer td
			| TCast(e1,None) ->
				Chunk.write_u8 writer.chunk 124;
				loop e1;
			| TCast(e1,Some md) ->
				Chunk.write_u8 writer.chunk 125;
				loop e1;
				let infos = t_infos md in
				let m = infos.mt_module in
				write_full_path writer (fst m.m_path) (snd m.m_path) (snd infos.mt_path);
			| TNew(({cl_kind = KTypeParameter ttp}),tl,el) ->
				Chunk.write_u8 writer.chunk 127;
				write_type_parameter_ref writer ttp;
				write_types writer tl;
				loop_el el;
			| TNew(c,tl,el) ->
				Chunk.write_u8 writer.chunk 126;
				write_class_ref writer c;
				write_types writer tl;
				loop_el el;
			(* unops 140-159 *)
			| TUnop(op,flag,e1) ->
				Chunk.write_u8 writer.chunk (140 + unop_index op flag);
				loop e1;
			(* binops 160-219 *)
			| TBinop(op,e1,e2) ->
				Chunk.write_u8 writer.chunk (160 + binop_index op);
				loop e1;
				loop e2;
			(* rest 250-254 *)
			| TIdent s ->
				Chunk.write_u8 writer.chunk 250;
				Chunk.write_string writer.chunk s;
		and loop_el el =
			Chunk.write_list writer.chunk el loop
		in
		loop e

	and write_type_parameters_forward writer (ttps : typed_type_param list) =
		let write_type_parameter_forward ttp =
			write_path writer ttp.ttp_class.cl_path;
			write_pos writer ttp.ttp_class.cl_name_pos;
			let i = match ttp.ttp_host with
				| TPHType -> 0
				| TPHConstructor -> 1
				| TPHMethod -> 2
				| TPHEnumConstructor -> 3
				| TPHAnonField -> 4
				| TPHLocal -> 5
			in
			Chunk.write_u8 writer.chunk i
		in
		Chunk.write_list writer.chunk ttps write_type_parameter_forward

	and write_type_parameters_data writer (ttps : typed_type_param list) =
		let write_type_parameter_data ttp =
			let c = ttp.ttp_class in
			write_metadata writer c.cl_meta;
			write_types writer (get_constraints ttp);
			Chunk.write_option writer.chunk ttp.ttp_default (write_type_instance writer)
		in
		List.iter write_type_parameter_data ttps

	and write_type_parameters writer (ttps : typed_type_param list) =
		write_type_parameters_forward writer ttps;
		write_type_parameters_data writer ttps;

	(* Fields *)

	and write_field_kind writer = function
		| Method MethNormal -> Chunk.write_u8 writer.chunk 0;
		| Method MethInline -> Chunk.write_u8 writer.chunk 1;
		| Method MethDynamic -> Chunk.write_u8 writer.chunk 2;
		| Method MethMacro -> Chunk.write_u8 writer.chunk 3;
		(* normal read *)
		| Var {v_read = AccNormal; v_write = AccNormal } -> Chunk.write_u8 writer.chunk 10
		| Var {v_read = AccNormal; v_write = AccNo } -> Chunk.write_u8 writer.chunk 11
		| Var {v_read = AccNormal; v_write = AccNever } -> Chunk.write_u8 writer.chunk 12
		| Var {v_read = AccNormal; v_write = AccCtor } -> Chunk.write_u8 writer.chunk 13
		| Var {v_read = AccNormal; v_write = AccCall } -> Chunk.write_u8 writer.chunk 14
		(* inline read *)
		| Var {v_read = AccInline; v_write = AccNever } -> Chunk.write_u8 writer.chunk 20
		(* getter read *)
		| Var {v_read = AccCall; v_write = AccNormal } -> Chunk.write_u8 writer.chunk 30
		| Var {v_read = AccCall; v_write = AccNo } -> Chunk.write_u8 writer.chunk 31
		| Var {v_read = AccCall; v_write = AccNever } -> Chunk.write_u8 writer.chunk 32
		| Var {v_read = AccCall; v_write = AccCtor } -> Chunk.write_u8 writer.chunk 33
		| Var {v_read = AccCall; v_write = AccCall } -> Chunk.write_u8 writer.chunk 34
		(* weird/overlooked combinations *)
		| Var {v_read = r;v_write = w } ->
			Chunk.write_u8 writer.chunk 100;
			let f = function
				| AccNormal -> Chunk.write_u8 writer.chunk 0
				| AccNo -> Chunk.write_u8 writer.chunk 1
				| AccNever -> Chunk.write_u8 writer.chunk 2
				| AccCtor -> Chunk.write_u8 writer.chunk 3
				| AccCall -> Chunk.write_u8 writer.chunk 4
				| AccInline -> Chunk.write_u8 writer.chunk 5
				| AccRequire(s,so) ->
					Chunk.write_u8 writer.chunk 6;
					Chunk.write_string writer.chunk s;
					Chunk.write_option writer.chunk so (Chunk.write_string writer.chunk)
			in
			f r;
			f w

	and open_field_scope writer (params : type_params) =
		writer.field_stack <- () :: writer.field_stack;
		let nested = in_nested_scope writer in
		let old_field_params = writer.field_type_parameters in
		let old_local_params = writer.local_type_parameters in
		if not nested then begin
			writer.local_type_parameters <- new identity_pool;
			writer.field_type_parameters <- new identity_pool;
		end;
		List.iter (fun ttp ->
			ignore(writer.field_type_parameters#add ttp ());
		) params;
		(fun () ->
			writer.field_type_parameters <- old_field_params;
			writer.local_type_parameters <- old_local_params;
			writer.field_stack <- List.tl writer.field_stack
		)

	and write_class_field_forward writer cf =
		Chunk.write_string writer.chunk cf.cf_name;
		write_pos writer cf.cf_pos;
		write_pos writer cf.cf_name_pos;
		Chunk.write_list writer.chunk cf.cf_overloads (fun cf ->
			write_class_field_forward writer cf;
		);

	and start_texpr writer (p: pos) =
		let restore = start_temporary_chunk writer 512 in
		let fctx = create_field_writer_context (PosWriter.create writer.stats writer.chunk p) in
		fctx,(fun () ->
			restore(fun new_chunk ->
				let restore = start_temporary_chunk writer 512 in
				if in_nested_scope writer then
					Chunk.write_u8 writer.chunk 0
				else begin
					Chunk.write_u8 writer.chunk 1;
					let ltp = List.map fst writer.local_type_parameters#to_list in
					write_type_parameters writer ltp
				end;
				let items,length = StringPool.get_sorted_items fctx.t_pool in
				Chunk.write_uleb128 writer.chunk length;
				List.iter (fun bytes ->
					Chunk.write_bytes writer.chunk (Bytes.unsafe_of_string bytes)
				) items;

				let items = fctx.vars#items in
				Chunk.write_uleb128 writer.chunk (DynArray.length items);
				DynArray.iter (fun v ->
					write_var writer fctx v;
				) items;
				Chunk.export_data new_chunk writer.chunk;
				restore(fun new_chunk -> new_chunk)
			)
		)

	and commit_field_type_parameters writer (params : type_params) =
		Chunk.write_uleb128 writer.chunk (List.length params);
		if in_nested_scope writer then
			Chunk.write_u8 writer.chunk 0
		else begin
			Chunk.write_u8 writer.chunk 1;
			let ftp = List.map fst writer.field_type_parameters#to_list in
			write_type_parameters writer ftp
		end

	and write_class_field_data writer (write_expr_immediately : bool) (cf : tclass_field) =
		let restore = start_temporary_chunk writer 512 in
		write_type_instance writer cf.cf_type;
		Chunk.write_uleb128 writer.chunk cf.cf_flags;
		Chunk.write_option writer.chunk cf.cf_doc (write_documentation writer);
		write_metadata writer cf.cf_meta;
		write_field_kind writer cf.cf_kind;
		let expr_chunk = match cf.cf_expr with
			| None ->
				Chunk.write_u8 writer.chunk 0;
				None
			| Some e when not write_expr_immediately ->
				Chunk.write_u8 writer.chunk 0;
				let fctx,close = start_texpr writer e.epos in
				write_texpr writer fctx e;
				Chunk.write_option writer.chunk cf.cf_expr_unoptimized (write_texpr writer fctx);
				let expr_chunk = close() in
				Some expr_chunk
			| Some e ->
				Chunk.write_u8 writer.chunk 1;
				let fctx,close = start_texpr writer e.epos in
				write_texpr writer fctx e;
				Chunk.write_option writer.chunk cf.cf_expr_unoptimized (write_texpr writer fctx);
				let expr_chunk = close() in
				Chunk.export_data expr_chunk writer.chunk;
				None
		in
		restore (fun new_chunk ->
			commit_field_type_parameters writer cf.cf_params;
			Chunk.export_data new_chunk writer.chunk
		);
		expr_chunk

	and write_class_field_and_overloads_data writer (write_expr_immediately : bool) (cf : tclass_field) =
		let cfl = cf :: cf.cf_overloads in
		Chunk.write_uleb128 writer.chunk (List.length cfl);
		ExtList.List.filter_map (fun cf ->
			let close = open_field_scope writer cf.cf_params in
			let expr_chunk = write_class_field_data writer write_expr_immediately cf in
			close();
			Option.map (fun expr_chunk -> (cf,expr_chunk)) expr_chunk
		) cfl

	(* Module types *)

	let select_type writer (path : path) =
		writer.type_type_parameters <- writer.type_param_lut#extract path

	let write_common_module_type writer (infos : tinfos) : unit =
		Chunk.write_bool writer.chunk infos.mt_private;
		Chunk.write_option writer.chunk infos.mt_doc (write_documentation writer);
		write_metadata writer infos.mt_meta;
		write_type_parameters_data writer infos.mt_params;
		Chunk.write_list writer.chunk infos.mt_using (fun (c,p) ->
			write_class_ref writer c;
			write_pos writer p;
		)

	let write_class_kind writer = function
		| KNormal ->
			Chunk.write_u8 writer.chunk 0
		| KTypeParameter ttp ->
			die "TODO" __LOC__
		| KExpr e ->
			Chunk.write_u8 writer.chunk 2;
			write_expr writer e;
		| KGeneric ->
			Chunk.write_u8 writer.chunk 3;
		| KGenericInstance(c,tl) ->
			Chunk.write_u8 writer.chunk 4;
			write_class_ref writer c;
			write_types writer tl
		| KMacroType ->
			Chunk.write_u8 writer.chunk 5;
		| KGenericBuild l ->
			Chunk.write_u8 writer.chunk 6;
			Chunk.write_list writer.chunk l (write_cfield writer);
		| KAbstractImpl a ->
			Chunk.write_u8 writer.chunk 7;
			write_abstract_ref writer a;
		| KModuleFields md ->
			Chunk.write_u8 writer.chunk 8

	let write_class writer (c : tclass) =
		begin match c.cl_kind with
		| KAbstractImpl a ->
			select_type writer a.a_path
		| _ ->
			select_type writer c.cl_path;
		end;
		write_common_module_type writer (Obj.magic c);
		write_class_kind writer c.cl_kind;
		Chunk.write_option writer.chunk c.cl_super (fun (c,tl) ->
			write_class_ref writer c;
			write_types writer tl
		);
		Chunk.write_list writer.chunk c.cl_implements (fun (c,tl) ->
			write_class_ref writer c;
			write_types writer tl
		);
		Chunk.write_option writer.chunk c.cl_dynamic (write_type_instance writer);
		Chunk.write_option writer.chunk c.cl_array_access (write_type_instance writer)

	let write_abstract writer (a : tabstract) =
		begin try
			select_type writer a.a_path
		with Not_found ->
			prerr_endline ("Could not select abstract " ^ (s_type_path a.a_path));
		end;
		write_common_module_type writer (Obj.magic a);
		Chunk.write_option writer.chunk a.a_impl (write_class_ref writer);
		if Meta.has Meta.CoreType a.a_meta then
			Chunk.write_u8 writer.chunk 0
		else begin
			Chunk.write_u8 writer.chunk 1;
			write_type_instance writer a.a_this;
		end;
		Chunk.write_list writer.chunk a.a_from (write_type_instance writer);
		Chunk.write_list writer.chunk a.a_to (write_type_instance writer);
		Chunk.write_bool writer.chunk a.a_enum

	let write_abstract_fields writer (a : tabstract) =
		let c = match a.a_impl with
			| None ->
				null_class
			| Some c ->
				c
		in

		Chunk.write_list writer.chunk a.a_array (write_field_ref writer c CfrStatic);
		Chunk.write_option writer.chunk a.a_read (write_field_ref writer c CfrStatic );
		Chunk.write_option writer.chunk a.a_write (write_field_ref writer c CfrStatic);
		Chunk.write_option writer.chunk a.a_call (write_field_ref writer c CfrStatic);

		Chunk.write_list writer.chunk a.a_ops (fun (op, cf) ->
			Chunk.write_u8 writer.chunk (binop_index op);
			write_field_ref writer c CfrStatic cf
		);

		Chunk.write_list writer.chunk a.a_unops (fun (op, flag, cf) ->
			Chunk.write_u8 writer.chunk (unop_index op flag);
			write_field_ref writer c CfrStatic cf
		);

		Chunk.write_list writer.chunk a.a_from_field (fun (t,cf) ->
			write_field_ref writer c CfrStatic cf;
		);

		Chunk.write_list writer.chunk a.a_to_field (fun (t,cf) ->
			write_field_ref writer c CfrStatic cf;
		)

	let write_enum writer (e : tenum) =
		select_type writer e.e_path;
		write_common_module_type writer (Obj.magic e);
		Chunk.write_bool writer.chunk e.e_extern;
		Chunk.write_list writer.chunk e.e_names (Chunk.write_string writer.chunk)

	let write_typedef writer (td : tdef) =
		select_type writer td.t_path;
		write_common_module_type writer (Obj.magic td);
		write_type_instance writer td.t_type

	(* Module *)

	let forward_declare_type writer (mt : module_type) =
		let name = ref "" in
		let i = match mt with
		| TClassDecl c ->
			ignore(writer.classes#add c.cl_path c);
			ignore(writer.own_classes#add c.cl_path c);
			name := snd c.cl_path;
			0
		| TEnumDecl e ->
			ignore(writer.enums#get_or_add e.e_path e);
			ignore(writer.own_enums#add e.e_path e);
			name := snd e.e_path;
			1
		| TTypeDecl t ->
			ignore(writer.typedefs#get_or_add t.t_path t);
			ignore(writer.own_typedefs#add t.t_path t);
			name := snd t.t_path;
			2
		| TAbstractDecl a ->
			ignore(writer.abstracts#add a.a_path a);
			ignore(writer.own_abstracts#add a.a_path a);
			name := snd a.a_path;
			3
		in

		let infos = t_infos mt in
		Chunk.write_u8 writer.chunk i;
		write_path writer (fst infos.mt_path, !name);
		write_pos writer infos.mt_pos;
		write_pos writer infos.mt_name_pos;
		write_type_parameters_forward writer infos.mt_params;
		let params = new pool in
		writer.type_type_parameters <- params;
		ignore(writer.type_param_lut#add infos.mt_path params);
		List.iter (fun ttp ->
			ignore(writer.type_type_parameters#add ttp.ttp_name ttp)
		) infos.mt_params;

		(* Forward declare fields *)
		match mt with
		| TClassDecl c ->
			Chunk.write_uleb128 writer.chunk c.cl_flags;
			Chunk.write_option writer.chunk c.cl_constructor (write_class_field_forward writer);
			Chunk.write_list writer.chunk c.cl_ordered_fields (write_class_field_forward writer);
			Chunk.write_list writer.chunk c.cl_ordered_statics (write_class_field_forward writer);
		| TEnumDecl e ->
			Chunk.write_list writer.chunk (PMap.foldi (fun s f acc -> (s,f) :: acc) e.e_constrs []) (fun (s,ef) ->
				Chunk.write_string writer.chunk s;
				write_pos writer ef.ef_pos;
				write_pos writer ef.ef_name_pos;
				Chunk.write_u8 writer.chunk ef.ef_index
			);
		| TAbstractDecl a ->
			()
		| TTypeDecl t ->
			()

	let write_module writer (m : module_def) =
		writer.current_module <- m;

		start_chunk writer MTF;
		Chunk.write_list writer.chunk m.m_types (forward_declare_type writer);

		begin match writer.own_abstracts#to_list with
		| [] ->
			()
		| own_abstracts ->
			start_chunk writer ABD;
			Chunk.write_list writer.chunk own_abstracts (write_abstract writer);
			start_chunk writer AFD;
			Chunk.write_list writer.chunk own_abstracts (write_abstract_fields writer);
		end;
		begin match writer.own_classes#to_list with
		| [] ->
			()
		| own_classes ->
			start_chunk writer CLD;
			Chunk.write_list writer.chunk own_classes (write_class writer);
			start_chunk writer CFD;
			let expr_chunks = ref [] in
			Chunk.write_list writer.chunk own_classes (fun c ->
				begin match c.cl_kind with
				| KAbstractImpl a ->
					select_type writer a.a_path
				| _ ->
					select_type writer c.cl_path;
				end;

				let c_expr_chunks = ref [] in
				let write_field ref_kind cf =
					let l = write_class_field_and_overloads_data writer false cf in
					List.iter (fun (cf,e) ->
						c_expr_chunks := (cf,ref_kind,e) :: !c_expr_chunks
					) l
				in

				Chunk.write_option writer.chunk c.cl_constructor (write_field CfrConstructor);
				Chunk.write_list writer.chunk c.cl_ordered_fields (write_field CfrMember);
				Chunk.write_list writer.chunk c.cl_ordered_statics (write_field CfrStatic);
				Chunk.write_option writer.chunk c.cl_init (fun e ->
					let fctx,close = start_texpr writer e.epos in
					write_texpr writer fctx e;
					let new_chunk = close() in
					Chunk.export_data new_chunk writer.chunk
				);
				match !c_expr_chunks with
				| [] ->
					()
				| c_expr_chunks ->
					expr_chunks := (c,c_expr_chunks) :: !expr_chunks
			);
			match !expr_chunks with
			| [] ->
				()
			| expr_chunks ->
				start_chunk writer EXD;
				Chunk.write_list writer.chunk expr_chunks (fun (c,l) ->
					write_class_ref writer c;
					Chunk.write_list writer.chunk l (fun (cf,ref_kind,e) ->
						write_field_ref writer c ref_kind cf;
						Chunk.export_data e writer.chunk
					)
				)
		end;
		begin match writer.own_enums#to_list with
		| [] ->
			()
		| own_enums ->
			start_chunk writer END;
			Chunk.write_list writer.chunk own_enums (write_enum writer);
			start_chunk writer EFD;
			Chunk.write_list writer.chunk own_enums (fun e ->
				Chunk.write_list writer.chunk (PMap.foldi (fun s f acc -> (s,f) :: acc) e.e_constrs []) (fun (s,ef) ->
					select_type writer e.e_path;
					let close = open_field_scope writer ef.ef_params in
					Chunk.write_string writer.chunk s;
					let restore = start_temporary_chunk writer 32 in
					write_type_instance writer ef.ef_type;
					let t_bytes = restore (fun new_chunk -> Chunk.get_bytes new_chunk) in
					commit_field_type_parameters writer ef.ef_params;
					Chunk.write_bytes writer.chunk t_bytes;
					Chunk.write_option writer.chunk ef.ef_doc (write_documentation writer);
					write_metadata writer ef.ef_meta;
					close();
				);
			)
		end;
		begin match writer.own_typedefs#to_list with
		| [] ->
			()
		| own_typedefs ->
			start_chunk writer TDD;
			Chunk.write_list writer.chunk own_typedefs (write_typedef writer);
		end;

		begin match writer.classes#to_list with
		| [] ->
			()
		| l ->
			start_chunk writer CLR;
			Chunk.write_list writer.chunk l (fun c ->
				let m = c.cl_module in
				write_full_path writer (fst m.m_path) (snd m.m_path) (snd c.cl_path);
			)
		end;
		begin match writer.abstracts#to_list with
		| [] ->
			()
		| l ->
			start_chunk writer ABR;
			Chunk.write_list writer.chunk l (fun a ->
				let m = a.a_module in
				write_full_path writer (fst m.m_path) (snd m.m_path) (snd a.a_path);
			)
		end;
		begin match writer.enums#to_list with
		| [] ->
			()
		| l ->
			start_chunk writer ENR;
			Chunk.write_list writer.chunk l (fun en ->
				let m = en.e_module in
				write_full_path writer (fst m.m_path) (snd m.m_path) (snd en.e_path);
			)
		end;
		begin match writer.typedefs#to_list with
		| [] ->
			()
		| l ->
			start_chunk writer TDR;
			Chunk.write_list writer.chunk l (fun td ->
				let m = td.t_module in
				write_full_path writer (fst m.m_path) (snd m.m_path) (snd td.t_path);
			)
		end;

		let items = writer.class_fields#items in
		if DynArray.length items > 0 then begin
			start_chunk writer CFR;
			Chunk.write_uleb128 writer.chunk (DynArray.length items);
			DynArray.iter (fun (cf,(c,kind,depth)) ->
				write_class_ref writer c;
				begin match kind with
				| CfrStatic ->
					Chunk.write_u8 writer.chunk 0;
					Chunk.write_string writer.chunk cf.cf_name
				| CfrMember ->
					Chunk.write_u8 writer.chunk 1;
					Chunk.write_string writer.chunk cf.cf_name
				| CfrConstructor ->
					Chunk.write_u8 writer.chunk 2;
				end;
				Chunk.write_uleb128 writer.chunk depth
			) items;
		end;

		let items = writer.enum_fields#items in
		if DynArray.length items > 0 then begin
			start_chunk writer EFR;
			Chunk.write_uleb128 writer.chunk (DynArray.length items);
			DynArray.iter (fun (en,ef) ->
				write_enum_ref writer en;
				Chunk.write_string writer.chunk ef.ef_name;
			) items;
		end;

		let items = writer.anon_fields#items in
		if DynArray.length items > 0 then begin
			start_chunk writer AFR;
			Chunk.write_uleb128 writer.chunk (DynArray.length items);
			DynArray.iter (fun (cf,_) ->
				write_class_field_forward writer cf
			) items;
		end;

		start_chunk writer MDF;
		write_path writer m.m_path;
		Chunk.write_string writer.chunk (Path.UniqueKey.lazy_path m.m_extra.m_file);
		Chunk.write_uleb128 writer.chunk (DynArray.length writer.anons#items);
		Chunk.write_uleb128 writer.chunk (DynArray.length writer.tmonos#items);
		start_chunk writer EOT;
		start_chunk writer EOF;
		start_chunk writer EOM;

		let finalize_string_pool kind items length =
			start_chunk writer kind;
			Chunk.write_uleb128 writer.chunk length;
			List.iter (fun s ->
				let b = Bytes.unsafe_of_string s in
				Chunk.write_bytes_length_prefixed writer.chunk b;
			) items
		in
		begin
			let items,length = StringPool.get_sorted_items writer.cp in
			finalize_string_pool STR items length
		end;
		begin
			let items,length = StringPool.get_sorted_items writer.docs in
			if length > 0 then
				finalize_string_pool DOC items length
		end

	let get_sorted_chunks writer =
		let l = DynArray.to_list writer.chunks in
		let l = List.sort (fun chunk1 chunk2 ->
			(Obj.magic chunk1.Chunk.kind - (Obj.magic chunk2.kind))
		) l in
		l
end

let create warn anon_id stats =
	let cp = StringPool.create ()in
{
	warn;
	anon_id;
	stats;
	current_module = null_module;
	chunks = DynArray.create ();
	cp = cp;
	docs = StringPool.create ();
	chunk = Obj.magic ();
	classes = new pool;
	enums = new pool;
	typedefs = new pool;
	abstracts = new pool;
	anons = new pool;
	anon_fields = new identity_pool;
	tmonos = new identity_pool;
	own_classes = new pool;
	own_abstracts = new pool;
	own_enums = new pool;
	own_typedefs = new pool;
	type_param_lut = new pool;
	class_fields = new hashed_identity_pool;
	enum_fields = new pool;
	type_type_parameters = new pool;
	field_type_parameters = new identity_pool;
	local_type_parameters = new identity_pool;
	field_stack = [];
	unbound_ttp = new identity_pool;
	t_instance_chunk = Chunk.create EOM cp 32;
}

let write_module writer m =
	HxbWriter.write_module writer m

let get_chunks writer =
	List.map (fun chunk ->
		(chunk.Chunk.kind,Chunk.get_bytes chunk)
	) (HxbWriter.get_sorted_chunks writer)

let export : 'a . hxb_writer -> 'a IO.output -> unit = fun writer ch ->
	write_header ch;
	let l = HxbWriter.get_sorted_chunks writer in
	List.iter (fun io ->
		Chunk.export writer.stats io ch
	) l