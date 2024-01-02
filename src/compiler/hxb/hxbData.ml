exception HxbFailure of string

(* TEMP: Wipe server cache to force loading from hxb *)
(* See ServerCompilationContext.after_compilation *)
(* Also see ServerTests.testDisplayModuleRecache test which needs updating if set to false *)
let always_wipe_cache = true

type chunk_kind =
	| STRI (* string pool *)
	| DOCS (* doc pool *)
	| HHDR (* module header *)
	| TYPF (* forward types *)
	(* Module type references *)
	| CLSR (* class reference array *)
	| ENMR (* enum reference array *)
	| ABSR (* abstract reference array *)
	| TPDR (* typedef reference array *)
	(* Own module type definitions *)
	| ANFR (* anon field references *)
	| CLSD (* class definition *)
	| ENMD (* enum definition *)
	| ABSD (* abstract definition *)
	| TPDD (* typedef definition *)
	(* Field references *)
	| ENFR (* enum field references *)
	| CFLR (* class field references *)
	(* Own field definitions *)
	| CFLD (* class fields *)
	| EFLD (* enum fields *)
	| AFLD (* abstract fields *)
	| HEND (* the end *)

let string_of_chunk_kind = function
	| STRI -> "STRI"
	| DOCS -> "DOCS"
	| HHDR -> "HHDR"
	| ANFR -> "ANFR"
	| TYPF -> "TYPF"
	| CLSR -> "CLSR"
	| ABSR -> "ABSR"
	| TPDR -> "TPDR"
	| ENMR -> "ENMR"
	| CLSD -> "CLSD"
	| ABSD -> "ABSD"
	| ENFR -> "ENFR"
	| CFLR -> "CFLR"
	| CFLD -> "CFLD"
	| AFLD -> "AFLD"
	| TPDD -> "TPDD"
	| ENMD -> "ENMD"
	| EFLD -> "EFLD"
	| HEND -> "HEND"

let chunk_kind_of_string = function
	| "STRI" -> STRI
	| "DOCS" -> DOCS
	| "HHDR" -> HHDR
	| "TYPF" -> TYPF
	| "CLSR" -> CLSR
	| "ABSR" -> ABSR
	| "TPDR" -> TPDR
	| "ENMR" -> ENMR
	| "CLSD" -> CLSD
	| "ABSD" -> ABSD
	| "ENFR" -> ENFR
	| "ANFR" -> ANFR
	| "CFLR" -> CFLR
	| "CFLD" -> CFLD
	| "AFLD" -> AFLD
	| "TPDD" -> TPDD
	| "ENMD" -> ENMD
	| "EFLD" -> EFLD
	| "HEND" -> HEND
	| name -> raise (HxbFailure ("Invalid chunk name: " ^ name))

let error (s : string) =
	Printf.eprintf "[error] %s\n" s;
	raise (HxbFailure s)

let hxb_version = 1
