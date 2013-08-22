(** High level interface to libasmir.

    The functions in this file should be used instead of calling Libasmir functions
    directly. These functions should be easier to use, and, unlike the Libasmir
    ones, will handle garbage collection.

    @author Ivan Jager
*)

open Asmir_consts
open Ast
open Big_int_Z
open BatListFull
open Frame_piqi
open Libasmir
open Libbfd
open Type
open Util

module BArray = Bigarray.Array1

exception Disassembly_error;;
exception Memory_error;;

type arch = Libbfd.bfd_architecture
type asmprogram = {asmp : Libasmir.asm_program_t;
		   arch : arch;
		   secs : section_ptr list;
                   (** Get executable code bytes *)
		   get_exec : int64 -> char;
                   (** Get any readable bytes. *)
                   get_readable : int64 -> char;
 }


let arch_i386 = Bfd_arch_i386
let arch_arm  = Bfd_arch_arm
(*more to come later when we support them*)

(** How many blocks to obtain when reading a FULL trace (not streaming) *)
let trace_blocksize = ref 100000L

module D = Debug.Make(struct let name = "Asmir" and default=`NoDebug end)
open D

module Status = Util.StatusPrinter

(* more verbose debugging *)
module DV = Debug.Make(struct let name = "AsmirV" and default=`NoDebug end)
(* module DCheck = Debug.Make(struct let name = "AsmirCheck" and default=`NoDebug end) *)

(* Debug output for testing*)
module DTest = Debug.Make(struct let name = "AsmirTest" and default=`NoDebug end)

(* maps a string variable to the var we are using for it *)
type varctx = (string,Var.t) Hashtbl.t

(** [gamma_create mem decls] creates a new varctx for use during translation.
    [mem] is the var that should be used for memory references, and [decls]
    should be a list of variables already in scope.
*)
let gamma_create mem decls : varctx =
  let h = Hashtbl.create 57 in
  List.iter (fun (Var.V(_,nm,_) as var) -> Hashtbl.add h nm var) decls;
  Hashtbl.add h "$mem" mem;
  Hashtbl.add h "mem" mem;
  h

let gamma_lookup (g:varctx) s =
  try Hashtbl.find g s
  with Not_found ->
    failwith("Disassembled code had undeclared variable '"^s^"'. Something is broken.")

let gamma_extend = Hashtbl.add

let gamma_unextend = Hashtbl.remove

let x86_regs = Asmir_vars.x86_regs
let x86_mem = Asmir_vars.x86_mem
let arm_regs = Asmir_vars.arm_regs
let all_regs = Asmir_vars.all_regs

let decls_for_arch = function
  | Bfd_arch_i386 -> x86_mem::x86_regs
  | Bfd_arch_arm  -> x86_mem::arm_regs
  | _ -> failwith "decls_for_arch: unsupported arch"

let gamma_for_arch = function
  | Bfd_arch_i386 -> gamma_create x86_mem x86_regs
  | Bfd_arch_arm  -> gamma_create x86_mem arm_regs
  | _ -> failwith "gamma_for_arch: unsupported arch"


let get_asmprogram_arch {arch=arch}= arch

let get_all_sections p =
  let arr,err = Libasmir.asmir_get_all_sections p in
  if err <= 0 then failwith "get_all_sections";
  arr

let get_all_asections p =
  get_all_sections p.asmp

let bfd_section_size = Libbfd.bfd_section_get_size
let bfd_section_vma = Libbfd.bfd_section_get_vma
let bfd_section_name = Libbfd.bfd_section_get_name

(** Is section s loaded? *)
let is_load s =
  let flags = bfd_section_get_flags s in
  Int64.logand Libbfd.sEC_LOAD flags <> 0L

(** Is section s code? *)
let is_code s =
  let flags = bfd_section_get_flags s in
  Int64.logand flags Libbfd.sEC_CODE <> 0L

let codeonly s = is_load s && is_code s
let loaded s = is_load s

(** Returns a list of [(addr,array)] tuples where [addr] is the
    starting address of a memory segment, and [array] is an array
    representing the memory starting at address [addr]. *)
let section_memory_helper ?(which=codeonly) prog secs =
  let bfd = Libasmir.asmir_get_bfd prog in
  let sc l s =
    let size = bfd_section_size s and vma = bfd_section_vma s
    and flags = bfd_section_get_flags s
    and name = bfd_section_name s in
    dprintf "Found section %s at %Lx with size %Ld. flags=%Lx" name vma size flags;
    if which s then
      (* if Int64.logand Libbfd.sEC_LOAD flags <> 0L then *)
      let (ok, a) = Libbfd.bfd_get_section_contents bfd s 0L size in
      if ok <> 0 then (vma, a)::l else (dprintf "failed."; l)
    else l
  in
  let bits = List.fold_left sc [] secs in
  bits

let section_contents ?(which=codeonly) prog secs =
  let bits = section_memory_helper ~which prog secs in
  let get a =
    (* let open Int64 in *)
    let (-) = Int64.sub in
    let rec f a = function [] -> raise Memory_error
      | (s,arr)::_ when a - s >= 0L && a - s < Int64.of_int(BArray.dim arr)  ->
	  arr.{Int64.to_int(a-s)}
      | _::b -> f a b
    in
    f a bits
  in
  get

let section_contents_list ?(which=codeonly) prog secs =
  let bits = section_memory_helper ~which prog secs in
  let (+) = Int64.add in
  let al l (base,arr) =
    (* [base, ..., base + len(arr)) *)
    foldn (fun l n -> (base + (Int64.of_int n), arr.{n})::l) l ((BArray.dim arr) - 1)
  in
  List.fold_left al [] bits

(** Open a binary file for translation *)
let open_program ?base filename =
  let base = match base with
    | None -> -1L
    | Some(x) -> x
  in
  let prog = Libasmir.asmir_open_file filename base in
    (* tell the GC how to free resources associated with prog *)
  Gc.finalise Libasmir.asmir_close prog;
  let secs = Array.to_list (get_all_sections prog)  in
  let get_exec = section_contents prog secs in
  let get_readable = section_contents ~which:loaded prog secs in 
 {asmp=prog; arch=Libasmir.asmir_get_asmp_arch prog; secs=secs; get_exec=get_exec; get_readable=get_readable}


let get_asm = function
  | Label(_,[Asm s])::_ -> s
  | _ -> ""

(** Translate only one address of a  Libasmir.asm_program_t to BAP *)
let asm_addr_to_bap {asmp=prog; arch=arch; get_exec=get_exec} addr =
  let (ir, na) = try
     let v = Disasm.disasm_instr arch get_exec addr in
     DV.dprintf "Disassembled %Lx directly" addr;
     v
   with Disasm_i386.Disasm_i386_exception s ->
     DTest.dprintf "BAP unknown disasm_instr %Lx: %s" addr s;
     DV.dprintf "disasm_instr %Lx: %s" addr s;
     let ir =
       Special(Printf.sprintf "Unknown instruction at %Lx: %s " addr s, [])::[]
     in
     Disasm_i386.ToIR.add_labels addr ir,
     Int64.add addr (Int64.of_int (Libasmir.asmir_get_instr_length prog addr))
  in
  let ir = match ir with
    | Label(l, [])::rest ->
      Label(l, [Asm(Libasmir.asmir_string_of_insn prog addr)])::rest
    | _ -> ir
  in (ir, na)

let flatten ll =
	List.rev (List.fold_left (fun accu l -> List.rev_append l accu) [] ll)

(* asmprogram_to_bap_range p st en will read bytes at [st,en) from p and 
   translate them to bap *)
let asmprogram_to_bap_range ?(init_ro = false) p st en =
  let rec f l s =
    (* This odd structure is to ensure tail-recursion *)
    let t =
      try Some(asm_addr_to_bap p s)
      with Memory_error -> None in
    match t with
    | Some(ir, n) ->
      if n >= en then flatten (List.rev (ir::l))
      else
	f (ir::l) n
    | None ->
      (* If we fail, hopefully it is because there were some random
    	 bytes at the end of the section that we tried to
    	 disassemble *)
      wprintf "Failed to read instruction byte while disassembling at address %#Lx; end of section at %#Lx" s en;
      flatten (List.rev l)
  in
  f [] st

let asmprogram_section_to_bap p s =
  let size = bfd_section_size s and vma = bfd_section_vma s in
  asmprogram_to_bap_range p vma (Int64.add vma size)

(** Translate an entire Libasmir.asm_program_t into a BAP program *)
let asmprogram_to_bap ?(init_ro=false) p =
  let irs = List.map
	(fun s ->
	  if is_code s then asmprogram_section_to_bap p s else []) p.secs in
  flatten irs

let bap_fully_modeled p =
  List.for_all (function
    | Special _ -> false
    | _ -> true) p

(* Returns a single ASM instruction (as a list IL statements) from a
   sequence of bytes. *)
let byte_insn_to_bap arch addr bytes =
  let prog = Libasmir.byte_insn_to_asmp arch addr bytes in
  let get_exec a = bytes.(Int64.to_int (Int64.sub a addr)) in
  let (pr, n) = asm_addr_to_bap {asmp=prog; arch=arch; secs=[]; get_exec=get_exec; get_readable=get_exec} addr in
  Libasmir.asmir_close prog;
  pr, Int64.sub n addr

(* Transforms a byte sequence (byte array), to a list of lists of IL
   statements *)
let byte_sequence_to_bap bytes arch addr =
  let prog = Libasmir.byte_insn_to_asmp arch addr bytes in
  let len = Array.length bytes in
  let end_addr = Int64.add addr (Int64.of_int len) in
  let get_exec a = bytes.(Int64.to_int (Int64.sub a addr)) in
  let rec read_all acc cur_addr =
    if cur_addr >= end_addr then List.rev acc
    else
      let prog, next = asm_addr_to_bap {asmp=prog; arch=arch; secs=[]; get_exec=get_exec; get_readable=get_exec} cur_addr in
      read_all (prog::acc) next
  in
  let il = read_all [] addr in
  Libasmir.asmir_close prog;
  il

(** Create a function suitable for [Stream.of_func] that gets one
    block at a time from getter function [f].

    The trace is over when [getf] returns [].
*)
let rec bap_get_block_from_f f =
(* SWXXX UGLY! copy and pasted from traces....better place to put/do this? *)
  let trace_to_blocks trace = 
    let endtrace = "This is the final trace block" in
    let is_seed_label = (=) "ReadSyscall" in
    let rec to_blocks blocks current = function
      | [] ->
        List.rev ((List.rev current)::blocks)
      | (Ast.Label (Addr _, _) as l)::rest ->
        let block = List.rev current in
        to_blocks (block::blocks) [l] rest
      | (Ast.Comment (c, _) as s)::rest when c = endtrace || (is_seed_label c) ->
        let block = List.rev current in
        to_blocks (block::blocks) [s] rest
      | x::rest ->
        to_blocks blocks (x::current) rest
    in
    to_blocks [] [] trace
  in
  let block_q = Queue.create () in
  (fun off ->
    let refill () =
      match f () with
      | [] -> false
      | trace ->
        Printexc.print Typecheck.typecheck_prog trace;
        let blocks = trace_to_blocks trace in
        List.iter (fun x -> Queue.push x block_q) blocks;
        true
    in
    try
      Some(Queue.take block_q)
    with Queue.Empty ->
      (match refill() with
      | true -> Some(Queue.take block_q)
      | false -> None))

  let add_operands stmts ops =
    match stmts with
    | Label (l,a)::others ->
      Label (l,a@ops)::others
    | Comment (s,a)::others ->
      Comment (s,a@ops)::others
    | others when ops <> [] -> Comment("Attrs without label.", ops)::others
    | others -> others

(** The new protobuffers/piqi serialized trace format. *)
module SerializedTrace = struct

  let new_bap_from_trace_frames ?n r =
    print_mem_usage();
    let get_attrs =
      let convert_taint = function
        | `no_taint -> Taint 0
        | `taint_id(id) -> Taint (Int64.to_int id)
        | `taint_multiple -> Taint (-1)
      in
      let convert_usage = function
        | {Operand_usage.read=true; Operand_usage.written=true} -> Type.RW
        | {Operand_usage.read=true} -> Type.RD
        | {Operand_usage.written=true} -> Type.WR
        | _ -> (* Trace usage undefined; assuming read *) Type.RD
      in
      let convert_operand_info = function
        | {Operand_info.operand_info_specific=`mem_operand({Mem_operand.address=a});
           Operand_info.bit_length=b;
           Operand_info.operand_usage=use;
           Operand_info.taint_info=t;
           Operand_info.value=v} ->
          Context({name="mem";
                   mem=true;
                   t=Reg b;
                   index=a;
                   value=Util.big_int_of_binstring ~e:`Little v;
                   usage=convert_usage use;
                   taint=convert_taint t})
        | {Operand_info.operand_info_specific=`reg_operand({Reg_operand.name=n});
           Operand_info.bit_length=b;
           Operand_info.operand_usage=use;
           Operand_info.taint_info=t;
           Operand_info.value=v} ->
          Context({name=n;
                   mem=false;
                   t=Reg b;
                   index=0L;
                   value=Util.big_int_of_binstring ~e:`Little v;
                   usage=convert_usage use;
                   taint=convert_taint t})
      in
      let convert_taint_info = function
        | {Taint_intro.addr=a;
           Taint_intro.taint_id=tid;
           Taint_intro.value=value} ->
          let v = match value with
            | Some x -> Util.big_int_of_binstring ~e:`Little x
            | None -> Big_int_convenience.bi0
          in
          Context({name="mem";
                   mem=true;
                   t=Reg 8;
                   index=a;
                   value=v;
                   usage=WR;
                   taint=Taint (Int64.to_int tid)})
      in
      let convert_thread_id x = Type.ThreadId (Int64.to_int x)
      in
      function
        | `std_frame({Std_frame.operand_list=ol; Std_frame.thread_id=tid}) -> (convert_thread_id tid) :: List.map convert_operand_info ol
        | `syscall_frame _ -> []
        | `exception_frame _ -> []
        | `taint_intro_frame({Taint_intro_frame.taint_intro_list=til}) -> List.map convert_taint_info til
        | `modload_frame _ -> []
        | `key_frame _ -> []
        | `metadata_frame _ -> []
    in
    let raise_frame arch f =
      let get_stmts =
        function
          | `std_frame(f) ->
      (* Convert string to byte array *)
            let a = Array.of_list (BatString.to_list f.Std_frame.rawbytes) in
            let stmts, _ = byte_insn_to_bap arch f.Std_frame.address a in
            stmts
          | `syscall_frame({Syscall_frame.number=callno;
                            Syscall_frame.address=addr;
                            Syscall_frame.thread_id=tid}) ->
            [Special(Printf.sprintf "Syscall number %Ld at %#Lx by thread %Ld" callno addr tid, [StrAttr "TraceKeep"]); Comment("All blocks must have two statements", [])]
          | `exception_frame({Exception_frame.exception_number=exceptno;
                              Exception_frame.thread_id=Some tid;
                              Exception_frame.from_addr=Some from_addr;
                              Exception_frame.to_addr=Some to_addr}) ->
            [Special(Printf.sprintf "Exception number %Ld by thread %Ld at %#Lx to %#Lx" exceptno tid from_addr to_addr, []);
             Comment("All blocks must have two statements", [])]
          | `exception_frame({Exception_frame.exception_number=exceptno}) ->
            [Special(Printf.sprintf "Exception number %Ld" exceptno, []);
             Comment("All blocks must have two statements", [])]
          | `taint_intro_frame(f) ->
            [Comment("ReadSyscall", []); Comment("All blocks must have two statements", [])]
          | `modload_frame({Modload_frame.module_name=name;
                            Modload_frame.low_address=lowaddr;
                            Modload_frame.high_address=highaddr}) ->
            [Special(Printf.sprintf "Loaded module '%s' at %#Lx to %#Lx" name lowaddr highaddr, []); Comment("All blocks must have two statements", [])]
          | `key_frame _ ->
      (* Implement key frame later *)
            []
          | `metadata_frame _ -> []
      in
      add_operands (get_stmts f) (get_attrs f)
    in
    let out = ref [] in
    let counter = ref 0L in
    let checkctr () =
      match n with
      | Some(n) -> !counter < n
      | None -> true
    in
    let blocksize = match n with | Some x -> x | None -> !trace_blocksize in
    while not r#end_of_trace && checkctr () do
      let frames = r#get_frames blocksize in
    (* XXX: Remove use of Obj.magic in an elegant way... *)
      out := List.rev_append (List.flatten (List.map (raise_frame (Obj.magic r#get_arch)) frames)) !out;
      counter := Int64.add !counter (Int64.of_int (List.length frames));
    done;

    List.rev !out

(** New trace file format: Read entire trace at once *)
  let new_bap_from_trace_file filename =
    let r = new Trace_container.reader filename in
    new_bap_from_trace_frames r

(** New trace format: Create a streamer *)
  let new_bap_stream_from_trace_file rate filename =
    let r = new Trace_container.reader filename in
    let f () = new_bap_from_trace_frames ~n:rate r in
    Stream.from (bap_get_block_from_f f)

end

let serialized_bap_stream_from_trace_file = SerializedTrace.new_bap_stream_from_trace_file
(* let bap_stream_from_trace_file = PinTrace.alt_bap_stream_from_trace_file *)

let serialized_bap_from_trace_file = SerializedTrace.new_bap_from_trace_file

(* End traces functions *)

let get_symbols ?(all=false) {asmp=p} =
  let f = if all then asmir_get_all_symbols else asmir_get_symbols in
  let (arr,err) = f p in
  (* Manually keep p live here. asmir_get_symbols uses memory pinned
     to the bfd stored in p.  When p is garbage collected, this memory is
     freed.  Unfortunately, this can happen while converting the symbols
     to ocaml objects, which generally causes a segmentation fault. By
     keeping p alive until at least after the function call, we can be
     sure all objects have been converted to ocaml objects before we free
     the bfd memory. *)
  gc_keepalive p;
  if err <= 0 then failwith "get_symbols";
  arr

let get_dynamic_symbols {asmp=p} =
  let (arr,err) = asmir_get_dynsymbols p in
  (* See note about liveness in get_symbols *)
  gc_keepalive p;
  if err <= 0 then failwith "get_dynamic_symbols";
  arr

(* XXX: Very inefficient *)
let find_symbol {asmp=p} name =
  let (arr,err) = asmir_get_all_symbols p in
  if err <= 0 then failwith "find_symbol";
  BatArray.find (fun sym -> if sym.bfd_symbol_name = name then true else false) arr

let get_flavour p = bfd_flavour (Libasmir.asmir_get_bfd p.asmp)

let get_section_startaddr p sectionname =
  Libasmir.asmir_get_sec_startaddr p.asmp sectionname

let get_section_endaddr p sectionname =
  Libasmir.asmir_get_sec_endaddr p.asmp sectionname

let get_base_address p =
  Libasmir.asmir_get_base_address p.asmp

let get_start_addr p =
  Libasmir.asmir_get_start_addr p.asmp

let get_asm_instr_string p s =
  Libasmir.asmir_string_of_insn p.asmp s

let get_asm_instr_string_range p s e =
  let s = ref s in
  let str = ref "" in
  (try
    while !s < e do

      str := !str ^ "; " ^ (get_asm_instr_string p !s);

      let len = Int64.of_int (Libasmir.asmir_get_instr_length p.asmp !s) in
      if len = -1L then raise Exit;
      s := Int64.add !s len
    done;
  with Exit -> ());
  !str

let get_exec_mem_contents {get_exec=get_exec} =
  get_exec

let get_exec_mem_contents_list {asmp=asmp; secs=secs} = section_contents_list ~which:is_code asmp secs

let get_readable_mem_contents {get_readable=get_readable} = get_readable

let get_readable_mem_contents_list {asmp=asmp; secs=secs} = section_contents_list ~which:loaded asmp secs
