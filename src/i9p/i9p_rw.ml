open Lwt.Infix
open Result

let ( >>*= ) x f =
  x >>= function
  | Ok y -> f y
  | Error _ as e -> Lwt.return e

type impossible
let doesnt_fail = function
  | Ok x -> x
  | Error (_:impossible) -> assert false

module Make (Tree : I9p_tree.S) = struct
  type t = {
    mutable root : Tree.Dir.t;
    mutex : Lwt_mutex.t;
  }

  let of_dir root = {
    root;
    mutex = Lwt_mutex.create ();
  }

  let root t = t.root

  (* Walk to [t.root/path] and process the resulting directory with [fn dir], then update
     all the parents back to the root. *)
  let update_dir ~file_on_path t path fn =
    Lwt_mutex.with_lock t.mutex @@ fun () ->
    let rec aux base path =
      match Irmin.Path.String_list.decons path with
      | None -> fn base
      | Some (p, ps) ->
          begin Tree.Dir.lookup base p >>= function
          | `None ->
              aux (Tree.Dir.empty (Tree.Dir.repo base)) ps
          | `Directory subdir ->
              aux subdir ps
          | `File f ->
              file_on_path f >>*= fun () ->
              aux (Tree.Dir.empty (Tree.Dir.repo base)) ps
          end >>*= fun new_subdir ->
          Tree.Dir.with_child base p (`Directory new_subdir) >|= fun x ->
          Ok x
    in
    aux t.root path >>*= fun new_root ->
    t.root <- new_root;
    Lwt.return (Ok ())

  let err_not_a_directory (_ : Tree.File.t) =
    Lwt.return (Error `Not_a_directory)

  let replace_with_dir (_ : Tree.File.t) =
    Lwt.return (Ok ())

  let update t path leaf value =
    let repo = Tree.Dir.repo t.root in
    update_dir ~file_on_path:err_not_a_directory t path @@ fun dir ->
    Tree.Dir.lookup dir leaf >>= function
    | `Directory _ -> Lwt.return (Error `Is_a_directory)
    | `File _ | `None ->
    Tree.Dir.with_child dir leaf (`File (Tree.File.of_data repo value)) >|= fun new_dir -> Ok new_dir

  let remove t path leaf =
    update_dir ~file_on_path:err_not_a_directory t path @@ fun dir ->
    Tree.Dir.without_child dir leaf >|= fun new_dir -> Ok new_dir

  let update_force t path leaf value =
    let repo = Tree.Dir.repo t.root in
    update_dir ~file_on_path:replace_with_dir t path (fun dir ->
      Tree.Dir.with_child dir leaf (`File (Tree.File.of_data repo value)) >|= fun new_dir -> Ok new_dir
    ) >|= doesnt_fail

  let remove_force t path leaf =
    update_dir ~file_on_path:replace_with_dir t path (fun dir ->
      Tree.Dir.without_child dir leaf >|= fun new_dir -> Ok new_dir
    ) >|= doesnt_fail

end