open Globals
open Ast
open DisplayPosition
open Common
open Type
open Error
open Typecore

type import_display_kind =
	| IDKPackage of string list
	| IDKModule of string list * string
	| IDKSubType of string list * string * string
	| IDKModuleField of string list * string * string
	| IDKSubTypeField of string list * string * string * string
	| IDK

type import_display = import_display_kind * pos

let convert_import_to_something_usable pt path =
	let rec loop pack m t = function
		| (s,p) :: l ->
			let is_lower = is_lower_ident s in
			let is_display_pos = encloses_position pt p in
			begin match is_lower,m,t with
				| _,None,Some _ ->
					die "" __LOC__ (* impossible, I think *)
				| true,Some m,None ->
					if is_display_pos then (IDKModuleField(List.rev pack,m,s),p)
					else (IDK,p) (* assume that we're done *)
				| _,Some m,Some t ->
					if is_display_pos then (IDKSubTypeField(List.rev pack,m,t,s),p)
					else (IDK,p)
				| true,None,None ->
					if is_display_pos then (IDKPackage (List.rev (s :: pack)),p)
					else loop (s :: pack) m t l
				| false,Some sm,None ->
					if is_display_pos then (IDKSubType (List.rev pack,sm,s),p)
					else loop pack m (Some s) l
				| false,None,None ->
					if is_display_pos then (IDKModule (List.rev pack,s),p)
					else loop pack (Some s) None l
			end
		| [] ->
			(IDK,null_pos)
	in
	loop [] None None path

let add_import_position ctx p path =
	let infos = ctx.m.curmod.m_extra.m_display in
	if not (PMap.mem p infos.m_import_positions) then
		infos.m_import_positions <- PMap.add p (ref false) infos.m_import_positions

let mark_import_position ctx p =
	try
		let r = PMap.find p ctx.m.curmod.m_extra.m_display.m_import_positions in
		r := true
	with Not_found ->
		()

let commit_import ctx path mode p =
	ctx.m.import_statements <- (path,mode) :: ctx.m.import_statements;
	if Filename.basename p.pfile <> "import.hx" then add_import_position ctx p path

let init_import ctx context_init path mode p =
	let rec loop acc = function
		| x :: l when is_lower_ident (fst x) -> loop (x::acc) l
		| rest -> List.rev acc, rest
	in
	let pack, rest = loop [] path in
	(match rest with
	| [] ->
		(match mode with
		| IAll ->
			ctx.m.wildcard_packages <- (List.map fst pack,p) :: ctx.m.wildcard_packages
		| _ ->
			(match List.rev path with
			(* p spans `import |` (to the display position), so we take the pmax here *)
			| [] -> DisplayException.raise_fields (DisplayToplevel.collect ctx TKType NoValue true) CRImport (DisplayTypes.make_subject None {p with pmin = p.pmax})
			| (_,p) :: _ -> Error.raise_typing_error "Module name must start with an uppercase letter" p))
	| (tname,p2) :: rest ->
		let p1 = (match pack with [] -> p2 | (_,p1) :: _ -> p1) in
		let p_type = punion p1 p2 in
		let md = ctx.g.do_load_module ctx (List.map fst pack,tname) p_type in
		let types = md.m_types in
		let not_private mt = not (t_infos mt).mt_private in
		let error_private p = raise_typing_error "Importing private declarations from a module is not allowed" p in
		let chk_private t p = if ctx.m.curmod != (t_infos t).mt_module && (t_infos t).mt_private then error_private p in
		let has_name name t = snd (t_infos t).mt_path = name in

		let fail_usefully name p =
			let target_kind,candidates = match String.get name 0 with
				(* TODO: cleaner way to get module fields? *)
				| 'a'..'z' -> "field", PMap.foldi (fun n _ acc -> n :: acc) (try (Option.get md.m_statics).cl_statics with | _ -> PMap.empty) []
				| _ -> "type", List.map (fun mt -> snd (t_infos mt).mt_path) types
			in
			raise_typing_error (StringError.string_error name
				candidates
				("Module " ^ s_type_path md.m_path ^ " does not define " ^ target_kind ^ " " ^ name)
			) p
		in

		let find_type tname = List.find (has_name tname) types in
		let get_type tname =
			let t = try
				find_type tname
			with Not_found ->
				fail_usefully tname p_type
			in
			chk_private t p_type;
			t
		in
		let check_alias mt name pname =
			if not (name.[0] >= 'A' && name.[0] <= 'Z') then
				raise_typing_error "Type aliases must start with an uppercase letter" pname;
			if ctx.is_display_file && DisplayPosition.display_position#enclosed_in pname then
				DisplayEmitter.display_module_type ctx mt pname;
		in
		let add_static_field c cf alias =
			let res = mk_resolution alias (RFieldImport(c,cf)) p in
			ctx.m.module_resolution <- res :: ctx.m.module_resolution;
		in
		let add_enum_constructor en ef alias =
			let res = mk_resolution alias (REnumConstructorImport(en,ef)) p in
			ctx.m.module_resolution <- res :: ctx.m.module_resolution;
		in
		let add_static_init t name s =
			match resolve_typedef t with
			| TClassDecl c | TAbstractDecl {a_impl = Some c} ->
				ignore(c.cl_build());
				let cf = PMap.find s c.cl_statics in
				let name = Option.default (cf.cf_name,null_pos) name in
				add_static_field c cf name
			| TEnumDecl en ->
				let ef = PMap.find s en.e_constrs in
				let name = Option.default (ef.ef_name,null_pos) name in
				add_enum_constructor en ef name
			| _ ->
				raise Not_found
		in
		(match mode with
		| INormal | IAsName _ ->
			let name = (match mode with IAsName n -> Some n | _ -> None) in
			(match rest with
			| [] ->
				begin match name with
				| None ->
					ctx.m.module_resolution <- (ExtList.List.filter_map (fun t ->
						if not_private t then
							Some (mk_resolution (t_name t,null_pos) (RTypeImport t) p)
						else
							None
					) types) @ ctx.m.module_resolution;
					Option.may (fun c ->
						context_init#add (fun () ->
							ignore(c.cl_build());
							List.iter (fun cf ->
								if has_class_field_flag cf CfPublic then
									add_static_field c cf (cf.cf_name,null_pos)
							) c.cl_ordered_statics
						);
					) md.m_statics
				| Some(newname,pname) ->
					let mt = get_type tname in
					check_alias mt newname pname;
					let res = mk_resolution (newname,pname) (RTypeImport mt) p2 in
					ctx.m.module_resolution <- res :: ctx.m.module_resolution;
				end
			| [tsub,p2] ->
				let pu = punion p1 p2 in
				(try
					let tsub = List.find (has_name tsub) types in
					chk_private tsub pu;
					let name = match name with
						| None ->
							(t_name tsub,null_pos)
						| Some(name,pname) ->
							check_alias tsub name pname;
							(name,pname)
					in
					let res = mk_resolution name (RTypeImport tsub) p2 in
					ctx.m.module_resolution <- res :: ctx.m.module_resolution
				with Not_found ->
					(* this might be a static property, wait later to check *)
					let find_main_type_static () =
						try
							let tmain = find_type tname in
							begin try
								add_static_init tmain name tsub
							with Not_found ->
								let parent,target_kind,candidates = match resolve_typedef tmain with
									| TClassDecl c ->
										"Class<" ^ (s_type_path c.cl_path) ^ ">",
										"field",
										PMap.foldi (fun name _ acc -> name :: acc) c.cl_statics []
									| TAbstractDecl {a_impl = Some c} ->
										"Abstract<" ^ (s_type_path md.m_path) ^ ">",
										"field",
										PMap.foldi (fun name _ acc -> name :: acc) c.cl_statics []
									| TEnumDecl e ->
										"Enum<" ^ s_type_path md.m_path ^ ">",
										"field",
										PMap.foldi (fun name _ acc -> name :: acc) e.e_constrs []
									| _ ->
										"Module " ^ s_type_path md.m_path,
										"field or subtype",
										(* TODO: cleaner way to get module fields? *)
										PMap.foldi (fun n _ acc -> n :: acc) (try (Option.get md.m_statics).cl_statics with | _ -> PMap.empty) []
								in

								display_error ctx.com (StringError.string_error tsub candidates (parent ^ " has no " ^ target_kind ^ " " ^ tsub)) p
							end
						with Not_found ->
							fail_usefully tsub p
					in
					context_init#add (fun() ->
						match md.m_statics with
						| Some c ->
							(try
								ignore(c.cl_build());
								let rec loop fl =
									match fl with
									| [] -> raise Not_found
									| cf :: rest ->
										if cf.cf_name = tsub then
											if not (has_class_field_flag cf CfPublic) then
												error_private p
											else
												let name = Option.default (cf.cf_name,null_pos) name in
												add_static_field c cf name;
										else
											loop rest
								in
								loop c.cl_ordered_statics
							with Not_found ->
								find_main_type_static ())
						| None ->
							find_main_type_static ()
					)
				)
			| (tsub,p2) :: (fname,p3) :: rest ->
				(match rest with
				| [] -> ()
				| (n,p) :: _ -> raise_typing_error ("Unexpected " ^ n) p);
				let tsub = get_type tsub in
				context_init#add (fun() ->
					try
						add_static_init tsub name fname
					with Not_found ->
						display_error ctx.com (s_type_path (t_infos tsub).mt_path ^ " has no field " ^ fname) (punion p p3)
				);
			)
		| IAll ->
			let t = (match rest with
				| [] -> get_type tname
				| [tsub,_] -> get_type tsub
				| _ :: (n,p) :: _ -> raise_typing_error ("Unexpected " ^ n) p
			) in
			context_init#add (fun() ->
				match resolve_typedef t with
				| TClassDecl c
				| TAbstractDecl {a_impl = Some c} ->
					ignore(c.cl_build());
					PMap.iter (fun _ cf -> if not (has_meta Meta.NoImportGlobal cf.cf_meta) then add_static_field c cf (cf.cf_name,null_pos)) c.cl_statics
				| TEnumDecl en ->
					PMap.iter (fun _ ef -> if not (has_meta Meta.NoImportGlobal ef.ef_meta) then add_enum_constructor en ef (ef.ef_name,null_pos)) en.e_constrs
				| _ ->
					raise_typing_error "No statics to import from this type" p
			)
		))

let handle_using ctx path p =
	let t = match List.rev path with
		| (s1,_) :: (s2,_) :: sl ->
			if is_lower_ident s2 then mk_type_path ((List.rev (s2 :: List.map fst sl)),s1)
			else mk_type_path ~sub:s1 (List.rev (List.map fst sl),s2)
		| (s1,_) :: sl ->
			mk_type_path (List.rev (List.map fst sl),s1)
		| [] ->
			DisplayException.raise_fields (DisplayToplevel.collect ctx TKType NoValue true) CRUsing (DisplayTypes.make_subject None {p with pmin = p.pmax});
	in
	let types = (match t.tsub with
		| None ->
			let md = ctx.g.do_load_module ctx (t.tpackage,t.tname) p in
			let types = List.filter (fun t -> not (t_infos t).mt_private) md.m_types in
			Option.map_default (fun c -> (TClassDecl c) :: types) types md.m_statics
		| Some _ ->
			let t = ctx.g.do_load_type_def ctx p t in
			[t]
	) in
	(* delay the using since we need to resolve typedefs *)
	let filter_classes types =
		let rec loop acc types = match types with
			| td :: l ->
				(match resolve_typedef td with
				| TClassDecl c | TAbstractDecl({a_impl = Some c}) ->
					loop ((c,p) :: acc) l
				| td ->
					loop acc l)
			| [] ->
				acc
		in
		loop [] types
	in
	types,filter_classes

let init_using ctx context_init path p =
	let types,filter_classes = handle_using ctx path p in
	(* do the import first *)
	ctx.m.module_resolution <- (List.map (fun mt -> mk_resolution (t_name mt,null_pos) (RTypeImport mt) p) types) @ ctx.m.module_resolution;
	context_init#add (fun() -> ctx.m.module_using <- filter_classes types @ ctx.m.module_using)
