(*

Copyright (c) 2007-2008 The Regents of the University of California
All rights reserved.

Authors: Luca de Alfaro, Ian Pye

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

3. The names of the contributors may not be used to endorse or promote
products derived from this software without specific prior written
permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

 *)

open Printf

(** This is a timeout for how long we wait for database locks. 
    If we wait longer than this, then the db is too busy, and we quit all work. 
    Notice that this provides an auto-throttling mechanism: if there are too many
    instances of coloring active at once, we won't get the lock quickly, and the 
    process will terminate. *)
let lock_timeout = 30

(** This is the top-level code of the wiki online xml evaluation. 
    This is used for testing only: *)
let db_user = ref "wikiuser"
let set_db_user u = db_user := u
let db_pass = ref ""
let set_db_pass p = db_pass := p
let db_name = ref "wikidb"
let set_db_name d = db_name := d
let log_name = ref "/dev/null"
let set_log_name d = log_name := d
let db_host_name = ref "localhost"
let set_db_host d = db_host_name := d
let db_port = ref 3306
let set_db_port d = db_port := d
let synch_log = ref false
let noop s = ()
let delete_all = ref false
let reputation_speed = ref 1.
let set_reputation_speed f = reputation_speed := f
let requested_rev_id = ref None
let set_requested_rev_id d = requested_rev_id := Some d

(* Figure out what to do and how we are going to do it. *)
let command_line_format = 
  [("-db_user", Arg.String set_db_user, "<string>: DB user to use (default: wikiuser)");
   ("-db_name", Arg.String set_db_name, "<string>: Name of the DB to use (default: wikidb)");
   ("-db_pass", Arg.String set_db_pass, "<string>: DB password");
   ("-db_host", Arg.String set_db_host, "<string>: DB host (default: localhost)");
   ("-db_port", Arg.Int set_db_port, "<int>: DB port (default: 3306)");
   ("-rev_id",  Arg.Int set_requested_rev_id, "<int>: (optional) revision ID that we want to ensure it is colored");
   ("-log_file", Arg.String set_log_name, "<filename>: Logger output file (default: /dev/null)");
   ("-rep_speed", Arg.Float set_reputation_speed, "<float>: Speed at which users gain reputation; 1.0 for large wikis");
   ("-delete_all", Arg.Set delete_all, ": Recomputes all reputations and trust from scratch.  BE CAREFUL!! This may take a LONG time for large wikis.");
  ]

let _ = Arg.parse command_line_format noop "
This command computes user reputations and text trust for a wiki. 
The command assumes that the wiki database already contains some special 
tables for reputation and trust, and computes the missing reputation and 
trust values, in chronological order.  The code is thread-safe, meaning
that more than one instance can be active at the same time; an instance
terminates when all the work is done, or if there are too many active
instances (measured not from the number of active instances, but from 
the amount of DB contention that is generated, so the code is 
auto-throttling).  The command can be called whenever someone edits a 
revision, in which case it will just color the latest revision 
according to trust, and it will update user reputations accordingly.

Usage: eval_online_wiki";;

let logger = new Online_log.logger !log_name !synch_log;;
let trust_coeff = Online_types.get_default_coeff;;
let f m n = !reputation_speed *. (trust_coeff.Online_types.dynamic_rep_scaling m n) in 
trust_coeff.Online_types.dynamic_rep_scaling <- f;;

(* This is the function that evaluates a revision. 
   The function is recursive, because if some past revision of the same page 
   that falls within the analysis horizon is not yet evaluated and colored
   for trust, it evaluates and colors it first. 
 *)
let rec evaluate_revision (db: Online_db.db) (page_id: int) (rev_id: int) : unit = 
  Printf.printf "Evaluating revision %d of page %d\n" rev_id page_id;
  try
    let page = new Online_page.page db logger page_id rev_id trust_coeff in
    page#eval
  with Online_page.Missing_trust (page_id', rev_id') -> begin
    (* We need to evaluate page_id', rev_id' first *)
    evaluate_revision db page_id' rev_id';
    evaluate_revision db page_id rev_id
  end;;

(* Does all the work of processing the given page and revision *)
let db = new Online_db.db !db_user !db_pass !db_name !db_host_name !db_port in
 
(* If requested, we erase all coloring, and we recompute it from scratch. *)
if !delete_all then db#delete_all true; 

(* Loops over all revisions, in chronological order, since the last colored one. *)
(* The obvious way would be to do a join, of the revisions which do NOT appear in the 
   colored table, sorted chronologically.  However, this can be quite inefficient for 
   large numbers of revisions.  So what we do is we retrieve the time t of the most recently
   colored revision, and then we pull from the db all revisions with time greater or 
   equal to t (equal, to handle revisions with the same timestamp). *)
let revs = 
  try begin 
    let timestamp = db#fetch_last_colored_rev_time in 
    match !requested_rev_id with 
      None -> db#fetch_all_revs_after timestamp
    | Some r_id -> db#fetch_all_revs_including_after r_id timestamp
  end with Online_db.DB_Not_Found -> db#fetch_all_revs 
in 

let tried : (int, unit) Hashtbl.t = Hashtbl.create 10 in 
let color_more_revisions = ref true in 
while !color_more_revisions do begin 
  match Mysql.fetch revs with 
    None -> color_more_revisions := false
  | Some r -> begin 
      let rev = Online_revision.make_revision r db in 
      let page_id = rev#get_page_id in 
      let rev_id  = rev#get_id in 
      (* Tries to acquire the page lock. 
	 If it succeeds, colors the page. 
	 We set the timeout for waiting as follows. 
	 - If the page has already been tried, we need to wait on it, so we choose a long timeout. 
	   If we don't get the page by the long timeout, this means that there is too much db 
	   lock contention (too many simultaneously active coloring processes), and we terminate. 
	 - If the page has not been tried yet, we set a short timeout, and if we don't get the lock,
	   we move on to the next revision. 
	 This algorithm ensures an "overtake by at most 1" property: if there are many coloring
	 processes active simultaneously, and r_k, r_{k+1} are two revisions of a page p, it is 
	 possible that a process is coloring r_k while another is coloring a revision r' after r_k 
	 belonging to a different page p', but this revision r' cannot be past r_{k+1}. 
       *)
      let already_tried = Hashtbl.mem tried page_id in 
      let got_it = 
	if already_tried 
        then db#get_page_lock page_id lock_timeout 
        else db#get_page_lock page_id 0 in 
      (* If we got it, we can color the page *)
      if got_it then begin 
	(* Processes page *)
	if already_tried then Hashtbl.remove tried page_id; 
	evaluate_revision db page_id rev_id;
	db#release_page_lock page_id
      end else begin 
	(* We could not get the lock.  
	   If we have already tried the page, this means we waited LONG time; 
	   we quit everything, as it means there is some problem. *)
	if already_tried 
	then color_more_revisions := false
	else Hashtbl.add tried page_id ();
      end (* not got it *)
    end (* for a revision r that needs to be colored *)
end done (* while there are revisions to color *)


