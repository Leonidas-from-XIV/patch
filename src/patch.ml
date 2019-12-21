module String = struct
  let is_prefix ~prefix str =
    let pl = String.length prefix in
    if String.length str < pl then
      false
    else
      String.sub str 0 (String.length prefix) = prefix

  let cut sep str =
    try
      let idx = String.index str sep
      and l = String.length str
      in
      let sidx = succ idx in
      Some (String.sub str 0 idx, String.sub str sidx (l - sidx))
    with
      Not_found -> None

  let cuts sep str =
    let rec doit acc s =
      match cut sep s with
      | None -> List.rev (s :: acc)
      | Some (a, b) -> doit (a :: acc) b
    in
    doit [] str

  let slice ?(start = 0) ?stop str =
    let stop = match stop with
      | None -> String.length str
      | Some x -> x
    in
    let len = stop - start in
    String.sub str start len

  let trim = String.trim

  let get = String.get

  let concat = String.concat

  let length = String.length

  let equal = String.equal
end

type hunk = {
  mine_start : int ;
  mine_len : int ;
  mine : string list ;
  their_start : int ;
  their_len : int ;
  their : string list ;
}

let unified_diff hunk =
  (* TODO *)
  String.concat "\n" (List.map (fun line -> "-" ^ line) hunk.mine @
                      List.map (fun line -> "+" ^ line) hunk.their)

let pp_hunk ppf hunk =
  Format.fprintf ppf "@@@@ -%d,%d +%d,%d @@@@\n%s"
    hunk.mine_start hunk.mine_len hunk.their_start hunk.their_len
    (unified_diff hunk)

let take data num =
  let rec take0 num data acc =
    match num, data with
    | 0, _ -> List.rev acc
    | n, x::xs -> take0 (pred n) xs (x :: acc)
    | _ -> invalid_arg "take0 broken"
  in
  take0 num data []

let drop data num =
  let rec drop data num =
    match num, data with
    | 0, _ -> data
    | n, _::xs -> drop xs (pred n)
    | _ -> invalid_arg "drop broken"
  in
  try drop data num with
  | Invalid_argument _ -> invalid_arg ("drop " ^ string_of_int num ^ " on " ^ string_of_int (List.length data))

(* TODO verify that it applies cleanly *)
let apply_hunk old (index, to_build) hunk =
  try
    let prefix = take (drop old index) (hunk.mine_start - index) in
    (hunk.mine_start + hunk.mine_len, to_build @ prefix @ hunk.their)
  with
  | Invalid_argument _ -> invalid_arg ("apply_hunk " ^ string_of_int index ^ " old len " ^ string_of_int (List.length old) ^
                                       " hunk start " ^ string_of_int hunk.mine_start ^ " hunk len " ^ string_of_int hunk.mine_len)

let to_start_len data =
  (* input being "?19,23" *)
  match String.cut ',' (String.slice ~start:1 data) with
  | None when data = "+1" -> (0, 1)
  | None when data = "-1" -> (0, 1)
  | None -> invalid_arg ("start_len broken in " ^ data)
  | Some (start, len) ->
     let start = int_of_string start in
     let st = if start = 0 then start else pred start in
     (st, int_of_string len)

let count_to_sl_sl data =
  if String.is_prefix ~prefix:"@@" data then
    (* input: "@@ -19,23 +19,12 @@ bla" *)
    (* output: ((19,23), (19, 12)) *)
    match List.filter (function "" -> false | _ -> true) (String.cuts '@' data) with
    | numbers::_ ->
       let nums = String.trim numbers in
       (match String.cut ' ' nums with
        | None -> invalid_arg "couldn't find space in count"
        | Some (mine, theirs) -> Some (to_start_len mine, to_start_len theirs))
    | _ -> invalid_arg "broken line!"
  else
    None

let sort_into_bags dir mine their m_nl t_nl str =
  if String.length str = 0 then
    None
  else if String.is_prefix ~prefix:"---" str then
    None
  else match String.get str 0, String.slice ~start:1 str with
    | ' ', data -> Some (`Both, (data :: mine), (data :: their), m_nl, t_nl)
    | '+', data -> Some (`Their, mine, (data :: their), m_nl, t_nl)
    | '-', data -> Some (`Mine, (data :: mine), their, m_nl, t_nl)
    | '\\', data ->
      (* diff: 'No newline at end of file' turns out to be context-sensitive *)
      (* so: -xxx\n\\No newline... means mine didn't have a newline *)
      (* but +xxx\n\\No newline... means theirs doesn't have a newline *)
      assert (data = " No newline at end of file");
      let my_nl, their_nl = match dir with
        | `Both -> true, true
        | `Mine -> true, t_nl
        | `Their -> m_nl, true
      in
      Some (dir, mine, their, my_nl, their_nl)
    | _ -> None

let to_hunk count data mine_no_nl their_no_nl =
  match count_to_sl_sl count with
  | None -> None, mine_no_nl, their_no_nl, count :: data
  | Some ((mine_start, mine_len), (their_start, their_len)) ->
    let rec step dir mine their mine_no_nl their_no_nl = function
      | [] -> (List.rev mine, List.rev their, mine_no_nl, their_no_nl, [])
      | x::xs -> match sort_into_bags dir mine their mine_no_nl their_no_nl x with
        | Some (dir, mine, their, mine_no_nl', their_no_nl') -> step dir mine their mine_no_nl' their_no_nl' xs
        | None -> (List.rev mine, List.rev their, mine_no_nl, their_no_nl, x :: xs)
    in
    let mine, their, mine_no_nl, their_no_nl, rest = step `Both [] [] mine_no_nl their_no_nl data in
    (Some { mine_start ; mine_len ; mine ; their_start ; their_len ; their }, mine_no_nl, their_no_nl, rest)

let rec to_hunks (mine_no_nl, their_no_nl, acc) = function
  | [] -> (List.rev acc, mine_no_nl, their_no_nl, [])
  | count::data -> match to_hunk count data mine_no_nl their_no_nl with
    | None, mine_no_nl, their_no_nl, rest -> List.rev acc, mine_no_nl, their_no_nl, rest
    | Some hunk, mine_no_nl, their_no_nl, rest -> to_hunks (mine_no_nl, their_no_nl, hunk :: acc) rest

type operation =
  | Edit of string
  | Rename of string * string
  | Delete of string
  | Create of string

let operation_eq a b = match a, b with
  | Edit a, Edit b -> String.equal a b
  | Rename (a, a'), Rename (b, b') -> String.equal a b && String.equal a' b'
  | Delete a, Delete b -> String.equal a b
  | Create a, Create b -> String.equal a b
  | _ -> false

let pp_operation ppf = function
  | Edit name ->
    Format.fprintf ppf "--- b/%s\n" name ;
    Format.fprintf ppf "+++ a/%s\n" name
  | Rename (old_name, new_name) ->
    Format.fprintf ppf "--- b/%s\n" old_name ;
    Format.fprintf ppf "+++ a/%s\n" new_name
  | Delete name ->
    Format.fprintf ppf "--- b/%s\n" name ;
    Format.fprintf ppf "+++ /dev/null\n"
  | Create name ->
    Format.fprintf ppf "--- /dev/null\n" ;
    Format.fprintf ppf "+++ q/%s\n" name

type t = {
  operation : operation ;
  hunks : hunk list ;
  mine_no_nl : bool ;
  their_no_nl : bool ;
}

let pp ppf t =
  pp_operation ppf t.operation ;
  List.iter (pp_hunk ppf) t.hunks

let operation_of_strings mine their =
  let get_filename_opt n =
    let s = match String.cut ' ' n with None -> n | Some (x, _) -> x in
    if s = "/dev/null" then
      None
    else if String.(is_prefix ~prefix:"a/" s || is_prefix ~prefix:"b/" s) then
      Some (String.slice ~start:2 s)
    else
      Some s
  in
  match get_filename_opt mine, get_filename_opt their with
  | None, Some n -> Create n
  | Some n, None -> Delete n
  | Some a, Some b -> if String.equal a b then Edit a else Rename (a, b)
  | None, None -> assert false (* ??!?? *)

let to_diff data =
  (* first locate --- and +++ lines *)
  let rec find_start = function
    | [] -> None
    | x::y::xs when String.is_prefix ~prefix:"---" x ->
      let mine = String.slice ~start:4 x and their = String.slice ~start:4 y in
      Some (operation_of_strings mine their, xs)
    | _::xs -> find_start xs
  in
  match find_start data with
  | Some (operation, rest) ->
    let hunks, mine_no_nl, their_no_nl, rest = to_hunks (false, false, []) rest in
    Some ({ operation ; hunks ; mine_no_nl ; their_no_nl }, rest)
  | None -> None

let to_lines = String.cuts '\n'

let to_diffs data =
  let lines = to_lines data in
  let rec doit acc = function
    | [] -> List.rev acc
    | xs -> match to_diff xs with
      | None -> List.rev acc
      | Some (diff, rest) -> doit (diff :: acc) rest
  in
  doit [] lines

let patch filedata diff =
  let old = match filedata with None -> [] | Some x -> to_lines x in
  let idx, lines = List.fold_left (apply_hunk old) (0, []) diff.hunks in
  let lines = lines @ drop old idx in
  let lines =
    match diff.mine_no_nl, diff.their_no_nl with
    | false, true -> (match List.rev lines with ""::tl -> List.rev tl | _ -> lines)
    | true, false -> lines @ [ "" ]
    | false, false when filedata = None -> lines @ [ "" ]
    | false, false -> lines
    | true, true -> lines
  in
  Ok (String.concat "\n" lines)
