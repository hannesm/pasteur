open Brr
open Brr_io
open Brr_webcrypto
open Fut.Result_syntax

let sym_key_gen =
  let name = Crypto_algo.aes_cbc and length = 128 in
  Crypto_algo.Aes_key_gen_params.v ~name ~length ()

let sym_exportable_key s =
  let usages = Crypto_key.Usage.[ encrypt; decrypt; ] in
  Subtle_crypto.generate_key s sym_key_gen ~extractable:true ~usages

let iv =
  [| 0x48; 0x3b; 0x2e; 0xc4; 0x44; 0x0d; 0x2c; 0xb0; 0x46; 0xf4; 0xd5; 0x76; 0xa1; 0x94; 0x26; 0x0d; |]
let iv = Tarray.of_int_array Tarray.Uint8 iv |> Tarray.buffer

let sym_algo ?iv () =
  let iv = match iv with
    | Some iv -> iv
    | None ->
      let iv = Tarray.create Tarray.Uint8 16 in
      let () = Crypto.set_random_values Crypto.crypto iv in Tarray.buffer iv in
  Crypto_algo.Aes_cbc_params.v ~iv ()

let sym_encrypt ?iv s key clear =
  Subtle_crypto.encrypt s (sym_algo ?iv ()) key clear

let sym_decrypt ?iv s key cipher =
  Subtle_crypto.decrypt s (sym_algo ?iv ()) key cipher

let pasteur = Jstr.v "pasteur"
let err_element_pasteur_not_found = Jstr.v "No element with id 'pasteur' found"
let err_element_paste_not_found = Jstr.v "No paste element found"
let err_element_paste_is_not_a_string = Jstr.v "Paste element must be a string"
let err_invalid_hex_value = Jstr.v "Invalid hex value"
let err_invalid_key = Jstr.v "Invalid key!"
let err_server = Jstr.v "Error from the server"
let on = Jstr.v "on"
let post = Jstr.v "POST"
let disabled = Jstr.v "disabled"

let ( <.> ) f g = fun x -> f (g x)
let ( >>| ) x f = let+ x = x in f x
let id x = x

let make_path ?key ?ln ?hl ?raw code =
  let args = match ln, hl, raw with
    | Some true, Some v, Some true -> Fmt.str "?ln=true&hl=%s&raw=true" v
    | Some true, Some v, (Some false | None) -> Fmt.str "?ln=true&hl=%s" v
    | Some true, None, Some true -> Fmt.str "?ln=true&raw=true"
    | (Some false | None), Some v, Some true -> Fmt.str "?hl=%s&raw=true" v
    | (Some false | None), Some v, (Some false | None) -> Fmt.str "?hl=%s" v
    | Some true, None, (Some false | None) -> Fmt.str "?ln=true"
    | (Some false | None), None, Some true -> Fmt.str "?raw=true"
    | (Some false | None), None, (Some false | None) -> "" in
  match key with
  | Some key ->
    Fmt.kstr (Fut.ok <.> Jstr.of_string) "%s%s#%s" (Jstr.to_string code) args (Jstr.to_string key)
  | None -> Fmt.kstr (Fut.ok <.> Jstr.of_string) "%s%s" (Jstr.to_string code) args

let alert = Jv.get Jv.global "alert"
let alert v = ignore @@ Jv.apply alert Jv.[| of_string v |]

let handle_response ?key response =
  match Fetch.Response.status response with
  | 200 ->
    let* v = Fetch.Body.json (Fetch.Response.as_body response) in
    let code = Jv.get v "code" |> Jv.to_jstr in
    let hl = Jv.find v "hl" |> Option.map Jv.to_string in
    let ln = Jv.find v "ln" |> Option.map Jv.to_bool in
    let raw = Jv.find v "raw" |> Option.map Jv.to_bool in
    let* path = make_path ?hl ?ln ?raw ?key code in
    let* uri = Fut.return (Uri.of_jstr (Jstr.concat [ Uri.to_jstr (Window.location G.window); path ])) in
    Window.set_location G.window uri ; Fut.ok () 
  | 400 | 500 ->
    let* text = Fetch.Body.text (Fetch.Response.as_body response) in
    alert (Jstr.to_string text) ;
    Fut.return (Error (Jv.Error.v err_server))
  | _ ->
    alert "Invalid response from the server." ;
    Fut.return (Error (Jv.Error.v err_server))

let disable_button () =
  match Document.find_el_by_id G.document (Jstr.v "paste") with
  | None -> ()
  | Some el -> El.set_prop (El.Prop.bool disabled) true el

let enable_button () =
  match Document.find_el_by_id G.document (Jstr.v "paste") with
  | None -> ()
  | Some el -> El.set_prop (El.Prop.bool disabled) false el

let post () =
  disable_button () ;
  match Document.find_el_by_id G.document pasteur with
  | None ->
    enable_button () ;
    Fut.return (Error (Jv.Error.v err_element_pasteur_not_found))
  | Some el ->
    let form = Form.of_el el in
    let data = Form.Data.of_form form in
    ( match Form.Data.(find data (Jstr.v "paste")), Form.Data.(find data (Jstr.v "encrypted")) with
    | Some (`String str), Some (`String encrypted) when Jstr.equal encrypted on ->
      let subtl = Crypto.subtle Crypto.crypto in
      let clear = Tarray.of_jstr str in
      let* key  = sym_exportable_key subtl in
      let* cipher = sym_encrypt ~iv subtl key clear in
      let  cipher = Tarray.uint8_of_buffer cipher in
      let  cipher = Tarray.to_hex_jstr cipher in
      Form.Data.set data (Jstr.v "paste") cipher ;
      let init = Fetch.Request.init ~body:(Fetch.Body.of_form_data data) ~method':post () in
      let* key = Subtle_crypto.export_key subtl Crypto_key.Format.jwk key in
      let[@warning "-8"] (`Json_web_key key : [ `Buffer of _ | `Json_web_key of _ ]) = key in
      let* key = Fut.return (Base64.encode (Base64.data_of_binary_jstr (Json.encode key))) in
      let* res = Fetch.request (Fetch.Request.v ~init:init (Jstr.v "/")) in
      handle_response ~key res >>| enable_button
    | Some (`String _), _ ->
      let init = Fetch.Request.init ~body:(Fetch.Body.of_form_data data) ~method':post () in
      let* res = Fetch.request (Fetch.Request.v ~init:init (Jstr.v "/")) in
      handle_response res >>| enable_button
    | Some (`File _), _ ->
      enable_button () ;
      Fut.return (Error (Jv.Error.v err_element_paste_is_not_a_string))
    | None, _ ->
      enable_button () ;
      Fut.return (Error (Jv.Error.v err_element_paste_not_found)) )

let raw = Jstr.v "raw"
let output = Jstr.v "output"
let encrypted = Jstr.v "encrypted"
let err_source_or_output_not_found = Jstr.v "Source or Output not found"

let to_uint8 x y =
  let code chr = match chr with
    | '0' .. '9' -> Char.code chr - 48
    | 'a' .. 'f' -> 10 + Char.code chr - 97
    | 'A' .. 'F' -> 10 + Char.code chr - 65
    | _ -> invalid_arg "Invalid hex character" in
  (code x lsl 4 + code y)

let of_hex str =
  if str = "" then [||]
  else
    let len = String.length str in
    let buf = Array.make (len / 2) 0 in
    let rec go x y =
      if x >= len then ()
      else if y >= len then invalid_arg "Invalid hex value"
      else
        ( buf.(x / 2) <- to_uint8 str.[x] str.[y]
        ; go (x + 2) (y + 2) ) in
    go 0 1 ; buf

let of_hex str =
  try Ok (of_hex str)
  with _ -> Error (Jv.Error.v err_invalid_hex_value)

let show () =
  match Document.find_el_by_id G.document raw,
        Document.find_el_by_id G.document output,
        Document.find_el_by_id G.document encrypted with
  | Some src, Some output, Some encrypted when Jv.get (El.to_jv encrypted) "textContent" |> Jv.to_jstr = on ->
    let subtl = Crypto.subtle Crypto.crypto in
    let key = Uri.fragment (Window.location G.window) in
    let* key = Fut.return Rresult.(Base64.decode key >>= (Json.decode <.> Base64.data_to_binary_jstr)) in
    let* key = Subtle_crypto.import_key subtl Crypto_key.Format.jwk (`Json_web_key key)
      sym_key_gen
      ~extractable:false
      ~usages:Crypto_key.Usage.[ decrypt; ] in
    let  cipher = Jv.to_jstr (Jv.get (El.to_jv src) "textContent") in
    let* cipher = Fut.return (of_hex (Jstr.to_string cipher)) in
    let  cipher = Tarray.of_int_array Tarray.Uint8 cipher in
    let* clear = sym_decrypt ~iv subtl key cipher in
    let open Fut.Syntax in
    let* clear = Fut.return Tarray.(to_jstr (of_buffer Uint8 clear)) in
    ( match clear with
    | Ok clear -> El.set_children output El.[txt clear] ; Fut.ok ()
    | Error _ as err ->
      El.set_children output El.[txt err_invalid_key] ; Fut.return err )
  | Some src, Some output, _ ->
    let clear = Jv.to_jstr (Jv.get (El.to_jv src) "textContent") in
    El.set_children output El.[txt clear] ; Fut.ok ()
  | _ ->
    Fut.error (Jv.Error.v err_source_or_output_not_found)

let const x = fun _ -> x

let () =
  Jv.set Jv.global "doPost" (Jv.repr (fun () -> Fut.to_promise ~ok:(const Jv.undefined) (post ()))) ;
  Jv.set Jv.global "doShow" (Jv.repr (fun () -> Fut.to_promise ~ok:(const Jv.undefined) (show ())))

